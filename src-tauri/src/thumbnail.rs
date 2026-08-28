use std::{
    fs::{self, File},
    io::{BufReader, BufWriter},
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};
use exif::{In, Reader as ExifReader, Tag};
use image::{
    codecs::jpeg::JpegEncoder, imageops::FilterType, DynamicImage, GenericImageView, ImageReader,
};
use tokio::process::Command;
use uuid::Uuid;

use crate::{
    models::{CropRectNormalized, PreparedThumbnail, ThumbnailV1},
    tools,
};

const PREVIEW_MAX_DIMENSION: u32 = 1920;
const PREVIEW_JPEG_QUALITY: u8 = 90;

fn cache_directory() -> Result<PathBuf> {
    #[cfg(test)]
    let root = std::env::temp_dir()
        .join("ARTOFFICE-video-maker-tests")
        .join("thumbnail-previews");
    #[cfg(not(test))]
    let root = dirs::cache_dir()
        .context("Windowsのキャッシュフォルダーが見つかりません。")?
        .join("ARTOFFICE-video-maker")
        .join("thumbnail-previews");
    fs::create_dir_all(&root).context("サムネイル用キャッシュを作成できませんでした。")?;
    Ok(root)
}

fn is_heic(path: &Path) -> bool {
    path.extension().is_some_and(|extension| {
        extension.to_string_lossy().eq_ignore_ascii_case("heic")
            || extension.to_string_lossy().eq_ignore_ascii_case("heif")
    })
}

fn read_orientation(path: &Path) -> u32 {
    let Ok(file) = File::open(path) else { return 1 };
    let mut reader = BufReader::new(file);
    ExifReader::new()
        .read_from_container(&mut reader)
        .ok()
        .and_then(|exif| {
            exif.get_field(Tag::Orientation, In::PRIMARY)
                .and_then(|field| field.value.get_uint(0))
        })
        .unwrap_or(1)
}

fn apply_orientation(image: DynamicImage, orientation: u32) -> DynamicImage {
    match orientation {
        2 => image.fliph(),
        3 => image.rotate180(),
        4 => image.flipv(),
        5 => image.rotate90().fliph(),
        6 => image.rotate90(),
        7 => image.rotate270().fliph(),
        8 => image.rotate270(),
        _ => image,
    }
}

fn decode_standard(path: &Path) -> Result<(DynamicImage, u32)> {
    let orientation = read_orientation(path);
    let image = ImageReader::open(path)
        .context("画像を開けませんでした。")?
        .with_guessed_format()
        .context("画像形式を判定できませんでした。")?
        .decode()
        .context("画像を読み取れませんでした。")?;
    Ok((apply_orientation(image, orientation), orientation))
}

async fn decode_heic(path: &Path) -> Result<(DynamicImage, PathBuf)> {
    let magick = tools::magick()
        .context("HEICデコーダーが見つかりません。vendor-tools/imagemagickを準備してください。")?;
    let decoded = cache_directory()?.join(format!("decoded-{}.png", Uuid::new_v4()));
    let primary_image = format!("{}[0]", path.to_string_lossy());
    let mut command = Command::new(magick);
    tools::hide_console(&mut command);
    let output = command
        .arg(primary_image)
        .arg("-auto-orient")
        .arg("-strip")
        .arg(&decoded)
        .output()
        .await
        .context("HEICデコーダーを起動できませんでした。")?;
    anyhow::ensure!(
        output.status.success(),
        "HEIC画像を読み取れませんでした: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    );
    let image = ImageReader::open(&decoded)
        .context("変換したHEIC画像を開けませんでした。")?
        .decode()
        .context("変換したHEIC画像を読み取れませんでした。")?;
    Ok((image, decoded))
}

fn save_preview(image: DynamicImage, preview_path: &Path) -> Result<()> {
    let (source_width, source_height) = image.dimensions();
    let preview = if source_width > PREVIEW_MAX_DIMENSION || source_height > PREVIEW_MAX_DIMENSION {
        image.resize(
            PREVIEW_MAX_DIMENSION,
            PREVIEW_MAX_DIMENSION,
            FilterType::Lanczos3,
        )
    } else {
        image
    };
    let file =
        File::create(preview_path).context("サムネイルのプレビューを作成できませんでした。")?;
    let mut encoder = JpegEncoder::new_with_quality(BufWriter::new(file), PREVIEW_JPEG_QUALITY);
    encoder
        .encode_image(&preview.to_rgb8())
        .context("サムネイルのプレビューを保存できませんでした。")
}

pub async fn prepare(source_path: &str) -> Result<PreparedThumbnail> {
    let source = Path::new(source_path);
    anyhow::ensure!(source.is_file(), "集合写真が見つかりません。");
    let (image, orientation, decoded_temp) = if is_heic(source) {
        let (image, temporary) = decode_heic(source).await?;
        (image, 1, Some(temporary))
    } else {
        let (image, orientation) = decode_standard(source)?;
        (image, orientation, None)
    };
    let (source_width, source_height) = image.dimensions();
    let preview_path = cache_directory()?.join(format!("preview-{}.jpg", Uuid::new_v4()));
    let task_path = preview_path.clone();
    let preview_result = tokio::task::spawn_blocking(move || save_preview(image, &task_path)).await;
    if let Some(temporary) = decoded_temp {
        let _ = fs::remove_file(temporary);
    }
    preview_result.context("サムネイルのプレビュー処理が異常終了しました。")??;
    Ok(PreparedThumbnail {
        source_path: source_path.to_string(),
        preview_path: preview_path.to_string_lossy().into_owned(),
        source_width,
        source_height,
        exif_orientation: orientation,
    })
}

fn export_decoded(image: DynamicImage, crop: CropRectNormalized, destination: &Path) -> Result<()> {
    let (image_width, image_height) = image.dimensions();
    anyhow::ensure!(
        crop.x.is_finite()
            && crop.y.is_finite()
            && crop.width.is_finite()
            && crop.height.is_finite()
            && crop.width > 0.0
            && crop.height > 0.0,
        "サムネイルの切り抜き範囲が不正です。"
    );
    let mut x = (crop.x.clamp(0.0, 1.0) * image_width as f64).round() as u32;
    let mut y = (crop.y.clamp(0.0, 1.0) * image_height as f64).round() as u32;
    let mut width = (crop.width.clamp(0.0, 1.0) * image_width as f64)
        .round()
        .max(1.0) as u32;
    let mut height = (crop.height.clamp(0.0, 1.0) * image_height as f64)
        .round()
        .max(1.0) as u32;
    x = x.min(image_width.saturating_sub(1));
    y = y.min(image_height.saturating_sub(1));
    width = width.min(image_width - x);
    height = height.min(image_height - y);

    let target_ratio = 16.0 / 9.0;
    if width as f64 / height as f64 > target_ratio {
        let adjusted = (height as f64 * target_ratio).round() as u32;
        x += (width - adjusted) / 2;
        width = adjusted;
    } else {
        let adjusted = (width as f64 / target_ratio).round().max(1.0) as u32;
        y += (height - adjusted) / 2;
        height = adjusted;
    }

    let cropped = image.crop_imm(x, y, width, height);
    let resized = cropped
        .resize_exact(1920, 1080, FilterType::Lanczos3)
        .to_rgb8();
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent).context("サムネイルの保存先を作成できませんでした。")?;
    }
    let file = File::create(destination).context("サムネイルJPEGを作成できませんでした。")?;
    let mut encoder = JpegEncoder::new_with_quality(BufWriter::new(file), 92);
    encoder
        .encode_image(&resized)
        .context("サムネイルJPEGを保存できませんでした。")?;
    Ok(())
}

pub async fn export(thumbnail: &ThumbnailV1, destination: &Path) -> Result<()> {
    let source = Path::new(&thumbnail.source_path);
    anyhow::ensure!(source.is_file(), "サムネイルの元画像が見つかりません。");
    let (image, decoded_temp) = if is_heic(source) {
        let (image, temporary) = decode_heic(source).await?;
        (image, Some(temporary))
    } else {
        (decode_standard(source)?.0, None)
    };
    let crop = thumbnail.crop;
    let destination = destination.to_path_buf();
    let export_result =
        tokio::task::spawn_blocking(move || export_decoded(image, crop, &destination)).await;
    if let Some(temporary) = decoded_temp {
        let _ = fs::remove_file(temporary);
    }
    export_result.context("サムネイルの書き出し処理が異常終了しました。")??;
    Ok(())
}

pub fn cleanup_cache() {
    if let Ok(directory) = cache_directory() {
        let _ = fs::remove_dir_all(&directory);
        let _ = fs::create_dir_all(directory);
    }
}

#[cfg(test)]
mod tests {
    use super::{export, prepare};
    use crate::models::{CropRectNormalized, ThumbnailV1};
    use image::{GenericImageView, Rgb, RgbImage};

    #[tokio::test]
    async fn exports_exact_youtube_thumbnail_size() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("group.png");
        RgbImage::from_pixel(1200, 900, Rgb([220, 20, 40]))
            .save(&source)
            .unwrap();
        let prepared = prepare(source.to_str().unwrap()).await.unwrap();
        let destination = temp.path().join("thumb.jpg");
        let model = ThumbnailV1 {
            source_path: prepared.source_path,
            preview_path: prepared.preview_path,
            source_width: prepared.source_width,
            source_height: prepared.source_height,
            exif_orientation: 1,
            crop: CropRectNormalized {
                x: 0.0,
                y: 0.125,
                width: 1.0,
                height: 0.75,
            },
            zoom: 1.0,
        };
        export(&model, &destination).await.unwrap();
        let output = image::open(destination).unwrap();
        assert_eq!(output.dimensions(), (1920, 1080));
    }

    #[tokio::test]
    #[ignore = "set AOV_TEST_THUMBNAIL_PATH to run the supplied-image regression test"]
    async fn supplied_jpeg_regression_test() {
        let source = std::env::var("AOV_TEST_THUMBNAIL_PATH")
            .expect("AOV_TEST_THUMBNAIL_PATH must point to the supplied image");
        let prepared = prepare(&source).await.unwrap();
        assert!(prepared.source_width > 0);
        assert!(prepared.source_height > 0);

        let temp = tempfile::tempdir().unwrap();
        let destination = temp.path().join("supplied-thumbnail.jpg");
        let model = ThumbnailV1 {
            source_path: prepared.source_path,
            preview_path: prepared.preview_path,
            source_width: prepared.source_width,
            source_height: prepared.source_height,
            exif_orientation: prepared.exif_orientation,
            crop: CropRectNormalized {
                x: 0.0,
                y: 0.0,
                width: 1.0,
                height: 1.0,
            },
            zoom: 1.0,
        };
        export(&model, &destination).await.unwrap();
        let output = image::open(destination).unwrap();
        assert_eq!(output.dimensions(), (1920, 1080));
    }
}
