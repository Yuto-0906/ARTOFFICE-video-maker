use std::{
    collections::hash_map::DefaultHasher,
    fs,
    hash::{Hash, Hasher},
    path::{Path, PathBuf},
    time::Duration,
};

use anyhow::{Context, Result};
use tokio::{process::Command, sync::Mutex};
use uuid::Uuid;

use crate::{media, tools};

// Serialize preparation so switching clips cannot launch multiple long encodes.
static PREPARATION: Mutex<()> = Mutex::const_new(());

fn cache_directory() -> Result<PathBuf> {
    #[cfg(test)]
    let root = std::env::temp_dir().join("ARTOFFICE-video-maker-tests");
    #[cfg(not(test))]
    let root = dirs::cache_dir()
        .context("キャッシュフォルダーが見つかりません。")?
        .join("ARTOFFICE-video-maker");
    let directory = root.join("video-previews");
    fs::create_dir_all(&directory)?;
    Ok(directory)
}

struct TemporaryPreview(PathBuf);

impl Drop for TemporaryPreview {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

async fn encode(source: &Path, destination: &Path, copy_video: bool) -> Result<()> {
    let ffmpeg = tools::ffmpeg().context("FFmpegが見つかりません。")?;
    let mut command = Command::new(ffmpeg);
    tools::hide_console(&mut command);
    command
        .kill_on_drop(true)
        .args(["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i"])
        .arg(source)
        .args(["-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn"]);
    if copy_video {
        command.args(["-c:v", "copy"]);
    } else {
        command.args([
            "-vf", "scale=1280:720:force_original_aspect_ratio=decrease:force_divisible_by=2:reset_sar=1,format=yuv420p",
            "-c:v", "libx264", "-preset", "ultrafast", "-crf", "26", "-threads", "2",
        ]);
    }
    let output = command
        .args([
            "-c:a",
            "aac",
            "-ac",
            "2",
            "-b:a",
            "128k",
            "-movflags",
            "+faststart",
        ])
        .arg(destination)
        .output()
        .await
        .context("プレビュー変換を起動できませんでした。")?;
    anyhow::ensure!(
        output.status.success(),
        "プレビューを変換できませんでした: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    );
    Ok(())
}

pub async fn prepare(source_path: &str) -> Result<String> {
    let source = Path::new(source_path)
        .canonicalize()
        .context("元動画が見つかりません。")?;
    let metadata = fs::metadata(&source)?;
    anyhow::ensure!(metadata.is_file(), "元動画が見つかりません。");
    let mut hash = DefaultHasher::new();
    source.hash(&mut hash);
    metadata.len().hash(&mut hash);
    metadata.modified()?.hash(&mut hash);
    let destination = cache_directory()?.join(format!("{:016x}.mp4", hash.finish()));
    let _guard = PREPARATION.lock().await;
    if destination.is_file() {
        return Ok(destination.to_string_lossy().into_owned());
    }
    let temporary =
        TemporaryPreview(destination.with_file_name(format!("{}.partial.mp4", Uuid::new_v4())));
    let info = media::probe_one(&source).await?;
    // Rewrap compatible video without reducing quality or spending time on encoding.
    let copy_video = info.video_codec == "h264" && info.pixel_format == "yuv420p";
    if !copy_video || encode(&source, &temporary.0, true).await.is_err() {
        encode(&source, &temporary.0, false).await?;
    }
    fs::rename(&temporary.0, &destination)?;
    Ok(destination.to_string_lossy().into_owned())
}

pub fn cleanup_cache() {
    let Ok(directory) = cache_directory() else {
        return;
    };
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        let expired = entry.metadata().ok().is_some_and(|metadata| {
            metadata.is_file()
                && metadata
                    .modified()
                    .ok()
                    .and_then(|time| time.elapsed().ok())
                    .is_some_and(|age| age > Duration::from_secs(7 * 24 * 60 * 60))
        });
        if expired {
            let _ = fs::remove_file(entry.path());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command as StdCommand;

    #[tokio::test]
    async fn mixed_formats_prepare_playable_cached_previews_without_changing_sources() {
        let Some(ffmpeg) = tools::ffmpeg() else {
            return;
        };
        let temp = tempfile::tempdir().unwrap();
        for (extension, video, audio) in [
            ("mp4", "libx264", "aac"),
            ("mkv", "libx264", "flac"),
            ("mov", "libx264", "aac"),
            ("mts", "mpeg2video", "mp2"),
            ("m2ts", "libx264", "ac3"),
            ("avi", "mpeg4", "pcm_s16le"),
            ("wmv", "wmv2", "wmav2"),
            ("webm", "", ""),
        ] {
            let source = temp.path().join(format!("1_日本語のバンド.{extension}"));
            if extension == "webm" {
                fs::copy(
                    Path::new(env!("CARGO_MANIFEST_DIR")).join("../tests/fixtures/sample.webm"),
                    &source,
                )
                .unwrap();
            } else {
                let result = StdCommand::new(&ffmpeg)
                    .args([
                        "-hide_banner",
                        "-loglevel",
                        "error",
                        "-y",
                        "-f",
                        "lavfi",
                        "-i",
                        "testsrc2=s=96x64:r=30:d=1.5",
                        "-f",
                        "lavfi",
                        "-i",
                        "sine=frequency=440:sample_rate=48000:duration=1.5",
                        "-c:v",
                        video,
                        "-c:a",
                        audio,
                        "-ac",
                        "2",
                        "-shortest",
                    ])
                    .arg(&source)
                    .output()
                    .unwrap();
                assert!(
                    result.status.success(),
                    "{extension}: {}",
                    String::from_utf8_lossy(&result.stderr)
                );
            }
            let before = fs::read(&source).unwrap();
            let preview = prepare(source.to_str().unwrap())
                .await
                .unwrap_or_else(|error| panic!("{extension}: {error:#}"));
            let media = media::probe_one(Path::new(&preview)).await.unwrap();
            assert_eq!(media.video_codec, "h264", "{extension}");
            assert_eq!(media.audio_codec.as_deref(), Some("aac"), "{extension}");
            assert!(
                (media.duration_seconds - 1.5).abs() < 0.15,
                "{extension}: {}",
                media.duration_seconds
            );
            assert_eq!(prepare(source.to_str().unwrap()).await.unwrap(), preview);
            assert_eq!(fs::read(&source).unwrap(), before);
            fs::remove_file(preview).unwrap();
        }
    }
}
