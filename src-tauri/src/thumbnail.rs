use std::{
    fs::{self, File},
    io::{BufReader, BufWriter, Write},
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};
use exif::{In, Reader as ExifReader, Tag};
use image::{
    codecs::jpeg::JpegEncoder, imageops::FilterType, DynamicImage, GenericImageView, ImageReader,
};
#[cfg(not(target_os = "macos"))]
use tokio::process::Command;
use uuid::Uuid;

use crate::models::{CropRectNormalized, PreparedThumbnail, ThumbnailFormat, ThumbnailV1};
#[cfg(not(target_os = "macos"))]
use crate::tools;

const PREVIEW_MAX_DIMENSION: u32 = 1920;
const PREVIEW_JPEG_QUALITY: u8 = 90;

fn cache_directory() -> Result<PathBuf> {
    #[cfg(test)]
    let root = std::env::temp_dir()
        .join("ARTOFFICE-video-maker-tests")
        .join("thumbnail-previews");
    #[cfg(not(test))]
    let root = dirs::cache_dir()
        .context("キャッシュフォルダーが見つかりません。")?
        .join("ARTOFFICE-video-maker")
        .join("thumbnail-previews");
    fs::create_dir_all(&root).context("サムネイル用キャッシュを作成できませんでした。")?;
    Ok(root)
}

fn needs_system_decoder(path: &Path) -> bool {
    path.extension().is_some_and(|extension| {
        extension.to_string_lossy().eq_ignore_ascii_case("heic")
            || extension.to_string_lossy().eq_ignore_ascii_case("heif")
            || extension.to_string_lossy().eq_ignore_ascii_case("avif")
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

// AVIF and HEIF use the bundled decoder on Windows and ImageIO on macOS.
async fn decode_container(path: &Path) -> Result<DynamicImage> {
    let decoded = cache_directory()?.join(format!("decoded-{}.png", Uuid::new_v4()));
    let result = async {
        #[cfg(target_os = "macos")]
        {
            let source = path.to_path_buf();
            let destination = decoded.clone();
            tokio::task::spawn_blocking(move || {
                crate::macos_image::decode_to_png(&source, &destination)
            })
            .await
            .context("画像の読み込み処理が異常終了しました。")??;
        }
        #[cfg(not(target_os = "macos"))]
        {
            let magick = tools::magick().context("画像デコーダーが見つかりません。")?;
            let mut command = Command::new(magick);
            tools::hide_console(&mut command);
            let output = command
                .arg(format!("{}[0]", path.to_string_lossy()))
                .args(["-auto-orient", "-strip"])
                .arg(&decoded)
                .output()
                .await
                .context("画像デコーダーを起動できませんでした。")?;
            anyhow::ensure!(
                output.status.success(),
                "画像を読み取れませんでした: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }
        ImageReader::open(&decoded)
            .context("変換した画像を開けませんでした。")?
            .decode()
            .context("変換した画像を読み取れませんでした。")
    }
    .await;
    let _ = fs::remove_file(decoded);
    result
}

async fn decode_source(path: &Path) -> Result<(DynamicImage, u32)> {
    if needs_system_decoder(path) {
        Ok((decode_container(path).await?, 1))
    } else {
        let source = path.to_path_buf();
        tokio::task::spawn_blocking(move || decode_standard(&source))
            .await
            .context("画像の読み込み処理が異常終了しました。")?
    }
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
    let (image, orientation) = decode_source(source).await?;
    let (source_width, source_height) = image.dimensions();
    let preview_path = cache_directory()?.join(format!("preview-{}.jpg", Uuid::new_v4()));
    let task_path = preview_path.clone();
    let preview_result = tokio::task::spawn_blocking(move || save_preview(image, &task_path)).await;
    preview_result.context("サムネイルのプレビュー処理が異常終了しました。")??;
    Ok(PreparedThumbnail {
        source_path: source_path.to_string(),
        preview_path: preview_path.to_string_lossy().into_owned(),
        source_width,
        source_height,
        exif_orientation: orientation,
    })
}

fn export_decoded(
    image: DynamicImage,
    crop: CropRectNormalized,
    format: ThumbnailFormat,
    destination: &Path,
) -> Result<()> {
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
    let file = File::create(destination).context("サムネイルを作成できませんでした。")?;
    let mut writer = BufWriter::new(file);
    match format {
        ThumbnailFormat::Jpg => JpegEncoder::new_with_quality(&mut writer, 92)
            .encode_image(&resized)
            .context("サムネイルを保存できませんでした。")?,
        ThumbnailFormat::Png => DynamicImage::ImageRgb8(resized)
            .write_to(&mut writer, image::ImageFormat::Png)
            .context("サムネイルを保存できませんでした。")?,
    }
    writer
        .flush()
        .context("サムネイルを保存できませんでした。")?;
    Ok(())
}

pub async fn export(thumbnail: &ThumbnailV1, destination: &Path) -> Result<()> {
    let source = Path::new(&thumbnail.source_path);
    anyhow::ensure!(source.is_file(), "サムネイルの元画像が見つかりません。");
    let (image, _) = decode_source(source).await?;
    let crop = thumbnail.crop;
    let format = thumbnail.output_format;
    let destination = destination.to_path_buf();
    let export_result =
        tokio::task::spawn_blocking(move || export_decoded(image, crop, format, &destination))
            .await;
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
    async fn imports_additional_images_and_exports_real_png() {
        use crate::models::ThumbnailFormat;
        let temp = tempfile::tempdir().unwrap();
        for extension in ["webp", "tif", "tiff", "bmp", "gif", "avif"] {
            let source = temp.path().join(format!("集合写真.{extension}"));
            if extension == "avif" {
                #[cfg(not(target_os = "macos"))]
                if crate::tools::magick().is_none() {
                    continue;
                }
                std::fs::copy(
                    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                        .join("../tests/fixtures/sample.avif"),
                    &source,
                )
                .unwrap();
            } else {
                RgbImage::from_pixel(96, 64, Rgb([230, 10, 20]))
                    .save(&source)
                    .unwrap();
            }
            let prepared = prepare(source.to_str().unwrap())
                .await
                .unwrap_or_else(|error| panic!("{extension}: {error:#}"));
            assert_eq!((prepared.source_width, prepared.source_height), (96, 64));
            let model = ThumbnailV1 {
                source_path: prepared.source_path,
                preview_path: prepared.preview_path,
                source_width: 96,
                source_height: 64,
                exif_orientation: 1,
                zoom: 1.0,
                crop: CropRectNormalized {
                    x: 0.0,
                    y: 0.078125,
                    width: 1.0,
                    height: 0.84375,
                },
                output_format: ThumbnailFormat::Png,
            };
            // The format comes from the saved setting, including a staged filename.
            let destination = temp.path().join(format!("{extension}.partial.png"));
            export(&model, &destination).await.unwrap();
            let bytes = std::fs::read(&destination).unwrap();
            assert_eq!(&bytes[..8], b"\x89PNG\r\n\x1a\n");
            let output = image::open(&destination).unwrap();
            assert_eq!(output.dimensions(), (1920, 1080));
            let pixel = output.to_rgb8().get_pixel(960, 540).0;
            assert!(pixel[0] > 180 && pixel[1] < 50, "{extension}: {pixel:?}");
        }
    }

    #[tokio::test]
    async fn animated_gif_uses_first_frame() {
        use image::{
            codecs::gif::{GifEncoder, Repeat},
            Frame, Rgba, RgbaImage,
        };
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("animated.gif");
        let mut encoder = GifEncoder::new(std::fs::File::create(&source).unwrap());
        encoder.set_repeat(Repeat::Infinite).unwrap();
        encoder
            .encode_frame(Frame::new(RgbaImage::from_pixel(
                96,
                64,
                Rgba([255, 0, 0, 255]),
            )))
            .unwrap();
        encoder
            .encode_frame(Frame::new(RgbaImage::from_pixel(
                96,
                64,
                Rgba([0, 0, 255, 255]),
            )))
            .unwrap();
        drop(encoder);
        let prepared = prepare(source.to_str().unwrap()).await.unwrap();
        let preview = image::open(prepared.preview_path).unwrap().to_rgb8();
        assert!(preview.get_pixel(48, 32).0[0] > 240);
        assert!(preview.get_pixel(48, 32).0[2] < 20);
    }

    #[test]
    fn old_thumbnail_defaults_to_jpeg_and_png_setting_round_trips() {
        let json = serde_json::json!({"sourcePath":"group.png", "previewPath":"preview.jpg", "sourceWidth":96,
            "sourceHeight":64, "exifOrientation":1, "zoom":1,
            "crop":{"x":0,"y":0,"width":1,"height":1}});
        let mut model: ThumbnailV1 = serde_json::from_value(json).unwrap();
        assert_eq!(model.output_format.extension(), "jpg");
        model.output_format = crate::models::ThumbnailFormat::Png;
        let restored: ThumbnailV1 =
            serde_json::from_slice(&serde_json::to_vec(&model).unwrap()).unwrap();
        assert_eq!(restored.output_format.extension(), "png");
    }

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
            output_format: Default::default(),
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
            output_format: Default::default(),
        };
        export(&model, &destination).await.unwrap();
        let output = image::open(destination).unwrap();
        assert_eq!(output.dimensions(), (1920, 1080));
    }
}
