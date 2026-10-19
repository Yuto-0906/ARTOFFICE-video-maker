//! ImageIO applies HEIF container transforms and EXIF orientation before PNG export.
//! Only Apple system frameworks are linked; no image decoder needs to be installed.
use std::{
    ffi::{c_char, c_void},
    os::unix::ffi::OsStrExt,
    path::Path,
    ptr,
};

use anyhow::{ensure, Context, Result};

type Ref = *const c_void;

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(value: Ref);
    fn CFURLCreateFromFileSystemRepresentation(
        allocator: Ref,
        bytes: *const u8,
        length: isize,
        is_directory: bool,
    ) -> Ref;
    fn CFStringCreateWithCString(allocator: Ref, text: *const c_char, encoding: u32) -> Ref;
    fn CFNumberCreate(allocator: Ref, number_type: isize, value: *const c_void) -> Ref;
    fn CFNumberGetValue(number: Ref, number_type: isize, value: *mut c_void) -> bool;
    fn CFDictionaryGetValue(dictionary: Ref, key: Ref) -> Ref;
    fn CFDictionaryCreate(
        allocator: Ref,
        keys: *const Ref,
        values: *const Ref,
        count: isize,
        key_callbacks: Ref,
        value_callbacks: Ref,
    ) -> Ref;
    static kCFBooleanTrue: Ref;
    static kCFTypeDictionaryKeyCallBacks: u8;
    static kCFTypeDictionaryValueCallBacks: u8;
}

#[link(name = "ImageIO", kind = "framework")]
unsafe extern "C" {
    fn CGImageSourceCreateWithURL(url: Ref, options: Ref) -> Ref;
    fn CGImageSourceCopyPropertiesAtIndex(source: Ref, index: usize, options: Ref) -> Ref;
    fn CGImageSourceCreateThumbnailAtIndex(source: Ref, index: usize, options: Ref) -> Ref;
    fn CGImageDestinationCreateWithURL(url: Ref, kind: Ref, count: usize, options: Ref) -> Ref;
    fn CGImageDestinationAddImage(destination: Ref, image: Ref, properties: Ref);
    fn CGImageDestinationFinalize(destination: Ref) -> bool;
    static kCGImagePropertyPixelWidth: Ref;
    static kCGImagePropertyPixelHeight: Ref;
    static kCGImageSourceCreateThumbnailFromImageAlways: Ref;
    static kCGImageSourceCreateThumbnailWithTransform: Ref;
    static kCGImageSourceThumbnailMaxPixelSize: Ref;
}

/// Owns exactly one reference returned by a CoreFoundation/ImageIO Create or Copy call.
struct Owned(Ref);

impl Owned {
    fn new(value: Ref) -> Result<Self> {
        ensure!(
            !value.is_null(),
            "画像処理用のオブジェクトを作成できませんでした。"
        );
        Ok(Self(value))
    }
}

impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: Owned is created only for non-null, owned CF references.
        unsafe { CFRelease(self.0) }
    }
}

fn file_url(path: &Path) -> Result<Owned> {
    let bytes = path.as_os_str().as_bytes();
    // SAFETY: CF copies the valid byte slice during this call.
    Owned::new(unsafe {
        CFURLCreateFromFileSystemRepresentation(
            ptr::null(),
            bytes.as_ptr(),
            bytes.len() as isize,
            false,
        )
    })
}

fn dictionary(keys: &[Ref], values: &[Ref]) -> Result<Owned> {
    assert_eq!(keys.len(), values.len());
    // SAFETY: Callbacks retain the keys and values; both slices live throughout the call.
    Owned::new(unsafe {
        CFDictionaryCreate(
            ptr::null(),
            keys.as_ptr(),
            values.as_ptr(),
            keys.len() as isize,
            ptr::addr_of!(kCFTypeDictionaryKeyCallBacks).cast(),
            ptr::addr_of!(kCFTypeDictionaryValueCallBacks).cast(),
        )
    })
}

fn number(value: i64) -> Result<Owned> {
    // kCFNumberSInt64Type = 4. CF copies the number.
    Owned::new(unsafe { CFNumberCreate(ptr::null(), 4, ptr::from_ref(&value).cast()) })
}

fn dimension(properties: Ref, key: Ref) -> Result<i64> {
    let mut value = 0_i64;
    // SAFETY: ImageIO's width/height properties are CFNumber objects.
    let reference = unsafe { CFDictionaryGetValue(properties, key) };
    ensure!(!reference.is_null(), "画像の大きさを取得できませんでした。");
    let converted = unsafe { CFNumberGetValue(reference, 4, ptr::from_mut(&mut value).cast()) };
    ensure!(
        converted && value > 0 && value <= u32::MAX as i64,
        "画像の大きさが不正です。"
    );
    Ok(value)
}

pub fn decode_to_png(source_path: &Path, destination_path: &Path) -> Result<()> {
    let result = decode_inner(source_path, destination_path);
    if result.is_err() {
        let _ = std::fs::remove_file(destination_path);
    }
    result
}

fn decode_inner(source_path: &Path, destination_path: &Path) -> Result<()> {
    let source_url = file_url(source_path)?;
    // SAFETY: The URL is valid and all returned CF objects remain owned until use completes.
    unsafe {
        let source = Owned::new(CGImageSourceCreateWithURL(source_url.0, ptr::null()))
            .context("HEIC画像を開けませんでした。")?;
        let properties = Owned::new(CGImageSourceCopyPropertiesAtIndex(source.0, 0, ptr::null()))?;
        let max_dimension = dimension(properties.0, kCGImagePropertyPixelWidth)?
            .max(dimension(properties.0, kCGImagePropertyPixelHeight)?);
        let size = number(max_dimension)?;
        let options = dictionary(
            &[
                kCGImageSourceCreateThumbnailFromImageAlways,
                kCGImageSourceCreateThumbnailWithTransform,
                kCGImageSourceThumbnailMaxPixelSize,
            ],
            &[kCFBooleanTrue, kCFBooleanTrue, size.0],
        )?;
        // Use the full pixel dimensions, not an embedded reduced-size thumbnail.
        let image = Owned::new(CGImageSourceCreateThumbnailAtIndex(source.0, 0, options.0))
            .context("HEIC画像を読み取れませんでした。")?;
        let destination_url = file_url(destination_path)?;
        let png = Owned::new(CFStringCreateWithCString(
            ptr::null(),
            c"public.png".as_ptr(),
            0x0800_0100,
        ))?;
        let destination = Owned::new(CGImageDestinationCreateWithURL(
            destination_url.0,
            png.0,
            1,
            ptr::null(),
        ))?;
        // The pixels are already oriented. Do not copy the original orientation metadata.
        CGImageDestinationAddImage(destination.0, image.0, ptr::null());
        ensure!(
            CGImageDestinationFinalize(destination.0),
            "HEIC画像の変換結果を保存できませんでした。"
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{GenericImageView, Rgb, RgbImage};
    use std::process::Command;

    #[test]
    fn decodes_full_size_and_rejects_invalid_data() {
        let temp = tempfile::tempdir().unwrap();
        let png = temp.path().join("日本語の写真.png");
        RgbImage::from_pixel(80, 48, Rgb([230, 20, 40]))
            .save(&png)
            .unwrap();
        let decoded = temp.path().join("decoded.png");
        // PNG exercises the same ImageIO ownership/export path without a HEIC encoder.
        decode_to_png(&png, &decoded).unwrap();
        assert_eq!(image::open(&decoded).unwrap().dimensions(), (80, 48));
        let invalid = temp.path().join("invalid.heic");
        std::fs::write(&invalid, b"not an image").unwrap();
        assert!(decode_to_png(&invalid, &decoded).is_err());
        assert!(!decoded.exists());
    }

    #[test]
    fn reads_heic_with_orientation_and_thumbnail_crop() {
        let temp = tempfile::tempdir().unwrap();
        let png = temp.path().join("集合写真.png");
        let mut pixels = RgbImage::from_pixel(160, 96, Rgb([230, 20, 40]));
        for y in 0..48 {
            for x in 0..80 {
                pixels.put_pixel(x, y, Rgb([10, 30, 230]));
            }
        }
        pixels.save(&png).unwrap();
        let heic = temp.path().join("集合写真.heic");
        let output = Command::new("/usr/bin/sips")
            .args(["-s", "format", "heic"])
            .arg(&png)
            .arg("--out")
            .arg(&heic)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let output = Command::new("/usr/bin/sips")
            .args(["-s", "orientation", "6"])
            .arg(&heic)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let destination = temp.path().join("oriented.png");
        decode_to_png(&heic, &destination).unwrap();
        let oriented = image::open(&destination).unwrap();
        assert_eq!(oriented.dimensions(), (96, 160));
        // The original top-left blue patch must move to the top-right after a 90° turn.
        let blue = oriented.get_pixel(72, 20);
        assert!(blue[2] > blue[0] + 80);
        let red = oriented.get_pixel(20, 20);
        assert!(red[0] > red[2] + 80);
        let runtime = tokio::runtime::Runtime::new().unwrap();
        let prepared = runtime
            .block_on(crate::thumbnail::prepare(heic.to_str().unwrap()))
            .unwrap();
        assert_eq!((prepared.source_width, prepared.source_height), (96, 160));
        let thumbnail = crate::models::ThumbnailV1 {
            source_path: heic.to_string_lossy().into_owned(),
            preview_path: prepared.preview_path,
            source_width: prepared.source_width,
            source_height: prepared.source_height,
            exif_orientation: 1,
            zoom: 1.0,
            crop: crate::models::CropRectNormalized {
                x: 0.0,
                y: 0.0,
                width: 1.0,
                height: 1.0,
            },
        };
        let jpeg = temp.path().join("サムネイル.jpg");
        runtime
            .block_on(crate::thumbnail::export(&thumbnail, &jpeg))
            .unwrap();
        assert_eq!(image::open(jpeg).unwrap().dimensions(), (1920, 1080));
    }
}
