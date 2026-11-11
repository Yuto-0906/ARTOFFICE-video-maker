use crate::{media, tools};
use anyhow::{Context, Result};
use serde::Serialize;
use std::{
    collections::{hash_map::DefaultHasher, HashMap},
    fs,
    hash::{Hash, Hasher},
    path::{Path, PathBuf},
    sync::{LazyLock, Mutex},
    time::{Duration, Instant},
};
use tokio::{io::AsyncReadExt, process::Command};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

pub const WINDOW_SECONDS: f64 = 30.0;
struct Slot {
    generation: u64,
    cancellation: CancellationToken,
    updated: Instant,
}
static REQUESTS: LazyLock<Mutex<HashMap<String, Slot>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

pub fn begin(client: String, generation: u64) -> Result<CancellationToken> {
    let mut slots = REQUESTS.lock().unwrap();
    slots.retain(|_, slot| slot.updated.elapsed() < Duration::from_secs(3600));
    if let Some(slot) = slots.get(&client) {
        anyhow::ensure!(
            generation > slot.generation,
            "プレビューの準備を中止しました。"
        );
        slot.cancellation.cancel();
    }
    let cancellation = CancellationToken::new();
    slots.insert(
        client,
        Slot {
            generation,
            cancellation: cancellation.clone(),
            updated: Instant::now(),
        },
    );
    Ok(cancellation)
}

pub fn cancel(client: String, generation: u64) {
    let mut slots = REQUESTS.lock().unwrap();
    if slots
        .get(&client)
        .is_none_or(|s| generation >= s.generation)
    {
        if let Some(slot) = slots.get(&client) {
            slot.cancellation.cancel();
        }
        let cancellation = CancellationToken::new();
        cancellation.cancel();
        slots.insert(
            client,
            Slot {
                generation,
                cancellation,
                updated: Instant::now(),
            },
        );
    }
}

#[derive(Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedPreview {
    pub path: String,
    pub start_seconds: f64,
    pub end_seconds: f64,
}

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

async fn encode(
    source: &Path,
    destination: &Path,
    start: f64,
    copy_video: bool,
    copy_audio: bool,
    cancellation: &CancellationToken,
) -> Result<()> {
    let mut command = Command::new(tools::ffmpeg().context("FFmpegが見つかりません。")?);
    tools::hide_console(&mut command);
    command
        .kill_on_drop(true)
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-nostdin",
            "-y",
            "-ss",
        ])
        .arg(format!("{start:.9}"))
        .arg("-i")
        .arg(source)
        .args(["-t", "30", "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn"]);
    if copy_video {
        command.args(["-c:v", "copy"]);
    } else {
        command.args(["-vf", "scale=1280:720:force_original_aspect_ratio=decrease:force_divisible_by=2:reset_sar=1,format=yuv420p", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "26", "-maxrate", "6M", "-bufsize", "12M", "-threads", "2"]);
    }
    if copy_audio {
        command.args(["-c:a", "copy"]);
    } else {
        command.args(["-c:a", "aac", "-ac", "2", "-b:a", "128k"]);
    }
    command.args(["-movflags", "+faststart"]).arg(destination);
    command
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped());
    let mut child = command
        .spawn()
        .context("プレビュー変換を起動できませんでした。")?;
    let mut stderr = child
        .stderr
        .take()
        .context("変換ログを取得できませんでした。")?;
    let reader = tokio::spawn(async move {
        let mut bytes = Vec::new();
        stderr.read_to_end(&mut bytes).await.map(|_| bytes)
    });
    let status = tokio::select! {
        biased;
        _ = cancellation.cancelled() => {
            let _ = child.kill().await;
            let _ = child.wait().await;
            let _ = reader.await;
            anyhow::bail!("プレビューの準備を中止しました。");
        },
        status = child.wait() => status.context("プレビュー変換の終了を確認できませんでした。")?,
    };
    let stderr = reader.await??;
    anyhow::ensure!(
        status.success(),
        "プレビューを変換できませんでした: {}",
        String::from_utf8_lossy(&stderr).trim()
    );
    Ok(())
}

pub async fn prepare(
    source_path: &str,
    seconds: f64,
    cancellation: &CancellationToken,
) -> Result<PreparedPreview> {
    anyhow::ensure!(
        seconds.is_finite() && seconds >= 0.0,
        "プレビュー位置が不正です。"
    );
    let source = Path::new(source_path)
        .canonicalize()
        .context("元動画が見つかりません。")?;
    let metadata = fs::metadata(&source)?;
    anyhow::ensure!(metadata.is_file(), "元動画が見つかりません。");
    let info = tokio::select! {
        biased;
        _ = cancellation.cancelled() => anyhow::bail!("プレビューの準備を中止しました。"),
        info = media::probe_one(&source) => info?,
    };
    let start = (seconds.min((info.duration_seconds - 0.001).max(0.0)) / WINDOW_SECONDS).floor()
        * WINDOW_SECONDS;
    let end = (start + WINDOW_SECONDS).min(info.duration_seconds);
    let mut hash = DefaultHasher::new();
    "window-v2".hash(&mut hash);
    source.hash(&mut hash);
    metadata.len().hash(&mut hash);
    metadata.modified()?.hash(&mut hash);
    (start as u64).hash(&mut hash);
    let destination = cache_directory()?.join(format!("{:016x}.mp4", hash.finish()));
    let result = PreparedPreview {
        path: destination.to_string_lossy().into_owned(),
        start_seconds: start,
        end_seconds: end,
    };
    if destination.is_file() {
        return Ok(result);
    }
    let temporary =
        TemporaryPreview(destination.with_file_name(format!("{}.partial.mp4", Uuid::new_v4())));
    let copy_video = info.video_codec == "h264" && info.pixel_format == "yuv420p";
    let copy_audio = info.audio_codec.as_deref() == Some("aac");
    // Include keyframe preroll and container overhead，but never reserve a whole long recording.
    let source_rate = metadata.len() as f64 / info.duration_seconds.max(1.0);
    let required = ((WINDOW_SECONDS + 15.0) * source_rate.max(6_128_000.0 / 8.0) * 1.2) as u64;
    anyhow::ensure!(
        fs2::available_space(
            destination
                .parent()
                .context("キャッシュ保存先がありません。")?
        )? > required.saturating_add(100_000_000),
        "プレビュー用の空き容量が不足しています。"
    );
    if !copy_video
        || encode(&source, &temporary.0, start, true, copy_audio, cancellation)
            .await
            .is_err()
    {
        anyhow::ensure!(
            !cancellation.is_cancelled(),
            "プレビューの準備を中止しました。"
        );
        encode(&source, &temporary.0, start, false, false, cancellation).await?;
    }
    anyhow::ensure!(
        !cancellation.is_cancelled(),
        "プレビューの準備を中止しました。"
    );
    // Another window request may have finished the same cache entry first.
    if !destination.is_file() {
        fs::rename(&temporary.0, &destination)?;
    }
    Ok(result)
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

    #[test]
    fn newer_requests_cancel_old_jobs_and_reject_late_starts() {
        let client = Uuid::new_v4().to_string();
        let first = begin(client.clone(), 1).unwrap();
        let next = begin(client.clone(), 2).unwrap();
        assert!(first.is_cancelled());
        cancel(client.clone(), 1);
        assert!(!next.is_cancelled());
        cancel(client.clone(), 3);
        assert!(next.is_cancelled());
        assert!(begin(client, 3).is_err());
    }

    #[tokio::test]
    async fn windowed_copy_preserves_non_keyframe_timing_and_limits_size() {
        let ffmpeg = tools::ffmpeg().expect("FFmpeg");
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("long.mkv");
        let generated = StdCommand::new(&ffmpeg)
            .args([
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-f",
                "lavfi",
                "-i",
                "testsrc2=s=96x64:r=30:d=65",
                "-f",
                "lavfi",
                "-i",
                "sine=sample_rate=48000:duration=65",
                "-c:v",
                "libx264",
                "-g",
                "210",
                "-keyint_min",
                "210",
                "-sc_threshold",
                "0",
                "-c:a",
                "aac",
                "-shortest",
            ])
            .arg(&source)
            .output()
            .unwrap();
        assert!(
            generated.status.success(),
            "{}",
            String::from_utf8_lossy(&generated.stderr)
        );
        let before = fs::read(&source).unwrap();
        let preview = prepare(source.to_str().unwrap(), 34.567, &CancellationToken::new())
            .await
            .unwrap();
        assert_eq!(preview.start_seconds, 30.0);
        assert_eq!(preview.end_seconds, 60.0);
        let info = media::probe_one(Path::new(&preview.path)).await.unwrap();
        assert!(info.duration_seconds <= 30.15, "{}", info.duration_seconds);
        assert!(fs::metadata(&preview.path).unwrap().len() < before.len() as u64 * 3 / 4);
        let frame = |path: &Path, seconds: &str| {
            let output = StdCommand::new(&ffmpeg)
                .args(["-v", "error", "-ss", seconds, "-i"])
                .arg(path)
                .args([
                    "-frames:v",
                    "1",
                    "-f",
                    "rawvideo",
                    "-pix_fmt",
                    "yuv420p",
                    "-",
                ])
                .output()
                .unwrap();
            assert!(output.status.success());
            output.stdout
        };
        // The window begins between 28 s and 35 s keyframes. MP4 edit lists
        // must retain the exact source time，including its audio start offset.
        assert_eq!(
            frame(&source, "34.567"),
            frame(Path::new(&preview.path), "4.567")
        );
        assert_eq!(fs::read(&source).unwrap(), before);
        fs::remove_file(preview.path).unwrap();
    }

    #[tokio::test]
    #[ignore = "Read-only benchmark of a user-selected local recording"]
    async fn recording_preview_benchmark() {
        let source = std::env::var("AOV_PREVIEW_BENCHMARK_SOURCE").expect("source path");
        for seconds in [0.0, 600.0] {
            let start = Instant::now();
            let result = prepare(&source, seconds, &CancellationToken::new())
                .await
                .unwrap();
            println!(
                "window={}..{} prepared={:.3}s bytes={}",
                result.start_seconds,
                result.end_seconds,
                start.elapsed().as_secs_f64(),
                fs::metadata(&result.path).unwrap().len()
            );
            assert!(
                media::probe_one(Path::new(&result.path))
                    .await
                    .unwrap()
                    .duration_seconds
                    < 30.2
            );
            fs::remove_file(result.path).unwrap();
        }
    }

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
            let preview = prepare(source.to_str().unwrap(), 0.0, &CancellationToken::new())
                .await
                .unwrap_or_else(|error| panic!("{extension}: {error:#}"));
            let media = media::probe_one(Path::new(&preview.path)).await.unwrap();
            assert_eq!(media.video_codec, "h264", "{extension}");
            assert_eq!(media.audio_codec.as_deref(), Some("aac"), "{extension}");
            assert!(
                (media.duration_seconds - 1.5).abs() < 0.15,
                "{extension}: {}",
                media.duration_seconds
            );
            assert_eq!(
                prepare(source.to_str().unwrap(), 0.0, &CancellationToken::new())
                    .await
                    .unwrap(),
                preview
            );
            assert_eq!(fs::read(&source).unwrap(), before);
            fs::remove_file(preview.path).unwrap();
        }
    }
}
