use std::{
    fs,
    path::{Path, PathBuf},
    time::UNIX_EPOCH,
};

use anyhow::{Context, Result};
use serde::Deserialize;
use tokio::process::Command;

use crate::{
    models::{MediaInfo, ProbeResult, Rational, SourceFingerprint},
    tools,
};

#[derive(Debug, Deserialize)]
struct ProbeDocument {
    #[serde(default)]
    streams: Vec<ProbeStream>,
    format: Option<ProbeFormat>,
}

#[derive(Debug, Deserialize)]
struct ProbeStream {
    codec_type: Option<String>,
    codec_name: Option<String>,
    width: Option<u32>,
    height: Option<u32>,
    pix_fmt: Option<String>,
    color_space: Option<String>,
    field_order: Option<String>,
    avg_frame_rate: Option<String>,
    r_frame_rate: Option<String>,
    duration: Option<String>,
    nb_frames: Option<String>,
    sample_rate: Option<String>,
    channels: Option<u32>,
}

#[derive(Debug, Deserialize)]
struct ProbeFormat {
    duration: Option<String>,
}

fn parse_rational(text: &str) -> Rational {
    let (numerator, denominator) = text.split_once('/').unwrap_or((text, "1"));
    Rational {
        numerator: numerator.parse().unwrap_or(0),
        denominator: denominator.parse().unwrap_or(1),
    }
}

fn fingerprint(path: &Path) -> SourceFingerprint {
    let metadata = fs::metadata(path);
    let size = metadata.as_ref().map(fs::Metadata::len).unwrap_or(0);
    let modified_unix_ms = metadata
        .and_then(|value| value.modified())
        .ok()
        .and_then(|value| value.duration_since(UNIX_EPOCH).ok())
        .map(|value| value.as_millis() as u64)
        .unwrap_or(0);
    SourceFingerprint {
        size,
        modified_unix_ms,
    }
}

async fn probe_one(path: &Path) -> Result<MediaInfo> {
    anyhow::ensure!(path.is_file(), "元動画が見つかりません。");
    let ffprobe = tools::ffprobe().context("FFprobeが見つかりません。")?;
    let output = Command::new(ffprobe)
        .arg("-v")
        .arg("error")
        .arg("-show_format")
        .arg("-show_streams")
        .arg("-of")
        .arg("json")
        .arg(path)
        .output()
        .await
        .context("FFprobeを起動できませんでした。")?;
    anyhow::ensure!(
        output.status.success(),
        "動画を解析できませんでした: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    );
    let document: ProbeDocument =
        serde_json::from_slice(&output.stdout).context("FFprobeの結果を読み取れませんでした。")?;
    let video = document
        .streams
        .iter()
        .find(|stream| stream.codec_type.as_deref() == Some("video"))
        .context("映像ストリームがありません。")?;
    let audio = document
        .streams
        .iter()
        .find(|stream| stream.codec_type.as_deref() == Some("audio"));

    let fps = video
        .avg_frame_rate
        .as_deref()
        .or(video.r_frame_rate.as_deref())
        .map(parse_rational)
        .unwrap_or(Rational {
            numerator: 0,
            denominator: 1,
        });
    let duration_seconds = video
        .duration
        .as_deref()
        .or(document
            .format
            .as_ref()
            .and_then(|format| format.duration.as_deref()))
        .and_then(|value| value.parse::<f64>().ok())
        .unwrap_or(0.0);
    let frame_count = video
        .nb_frames
        .as_deref()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or_else(|| (duration_seconds * fps.value()).round().max(1.0) as u64);
    let width = video.width.unwrap_or(0);
    let height = video.height.unwrap_or(0);
    let video_codec = video.codec_name.clone().unwrap_or_default();
    let pixel_format = video.pix_fmt.clone().unwrap_or_default();
    let audio_codec = audio.and_then(|stream| stream.codec_name.clone());
    let sample_rate = audio
        .and_then(|stream| stream.sample_rate.as_deref())
        .and_then(|value| value.parse::<u32>().ok());
    let channels = audio.and_then(|stream| stream.channels);
    let mut reasons = Vec::new();
    if width != 1920 || height != 1080 {
        reasons.push(format!("解像度を1920×1080基準へ変換（{width}×{height}）"));
    }
    if (fps.value() - 60000.0 / 1001.0).abs() > 0.02 {
        reasons.push(format!(
            "フレームレートを59.94fpsへ変換（{:.3}fps）",
            fps.value()
        ));
    }
    if video_codec != "h264" {
        reasons.push(format!("映像をH.264へ変換（{video_codec}）"));
    }
    if pixel_format != "yuv420p" {
        reasons.push(format!("色形式をYUV 4:2:0へ変換（{pixel_format}）"));
    }
    if video
        .field_order
        .as_deref()
        .is_some_and(|order| order != "progressive" && order != "unknown")
    {
        reasons.push("映像をプログレッシブへ変換".to_string());
    }
    if audio_codec.as_deref() != Some("aac") {
        reasons.push(format!(
            "音声をAACへ変換（{}）",
            audio_codec.as_deref().unwrap_or("音声なし")
        ));
    }
    if sample_rate != Some(48_000) {
        reasons.push(format!(
            "音声を48kHzへ変換（{}Hz）",
            sample_rate.unwrap_or(0)
        ));
    }
    if channels != Some(2) {
        reasons.push(format!(
            "音声をステレオへ変換（{}ch）",
            channels.unwrap_or(0)
        ));
    }

    Ok(MediaInfo {
        duration_seconds,
        width,
        height,
        fps,
        frame_count,
        video_codec,
        pixel_format,
        color_space: video.color_space.clone(),
        audio_codec,
        sample_rate,
        channels,
        has_audio: audio.is_some(),
        needs_conversion: !reasons.is_empty(),
        conversion_reasons: reasons,
    })
}

pub async fn probe_paths(paths: Vec<String>) -> Vec<ProbeResult> {
    let mut results = Vec::with_capacity(paths.len());
    for raw_path in paths {
        let path = PathBuf::from(&raw_path);
        let file_name = path
            .file_name()
            .map(|value| value.to_string_lossy().into_owned())
            .unwrap_or_else(|| raw_path.clone());
        let source_fingerprint = fingerprint(&path);
        match probe_one(&path).await {
            Ok(media) => results.push(ProbeResult {
                path: raw_path,
                file_name,
                fingerprint: source_fingerprint,
                media: Some(media),
                error: None,
            }),
            Err(error) => results.push(ProbeResult {
                path: raw_path,
                file_name,
                fingerprint: source_fingerprint,
                media: None,
                error: Some(format!("{error:#}")),
            }),
        }
    }
    results
}

pub fn mp4_files(folder: &str) -> Result<Vec<String>> {
    let directory = Path::new(folder);
    anyhow::ensure!(directory.is_dir(), "フォルダーが見つかりません。");
    let mut paths = fs::read_dir(directory)
        .context("フォルダーを読み取れませんでした。")?
        .filter_map(|entry| entry.ok().map(|value| value.path()))
        .filter(|path| {
            path.is_file()
                && path.extension().is_some_and(|extension| {
                    extension.to_string_lossy().eq_ignore_ascii_case("mp4")
                })
        })
        .collect::<Vec<_>>();
    paths.sort_by(|a, b| {
        let order = |path: &Path| {
            path.file_stem()
                .and_then(|stem| stem.to_str())
                .and_then(|stem| stem.split_once('_'))
                .and_then(|(value, _)| value.parse::<u64>().ok())
                .unwrap_or(u64::MAX)
        };
        order(a).cmp(&order(b)).then_with(|| a.cmp(b))
    });
    Ok(paths
        .into_iter()
        .map(|path| path.to_string_lossy().into_owned())
        .collect())
}

#[cfg(test)]
mod tests {
    use std::process::Command as StdCommand;

    use super::{parse_rational, probe_one};
    use crate::tools;

    #[test]
    fn parses_ntsc_frame_rate() {
        let value = parse_rational("60000/1001");
        assert_eq!(value.numerator, 60000);
        assert_eq!(value.denominator, 1001);
        assert!((value.value() - 59.940_059).abs() < 0.001);
    }

    #[tokio::test]
    async fn flags_media_that_requires_conversion() {
        let Some(ffmpeg) = tools::ffmpeg() else {
            return;
        };
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("1_変換テスト.mp4");
        let generated = StdCommand::new(ffmpeg)
            .args([
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-f",
                "lavfi",
                "-i",
                "color=c=green:s=1280x720:r=30:d=0.5",
                "-f",
                "lavfi",
                "-i",
                "sine=frequency=440:sample_rate=44100:duration=0.5",
                "-shortest",
                "-c:v",
                "mpeg4",
                "-q:v",
                "5",
                "-c:a",
                "aac",
                "-ac",
                "1",
            ])
            .arg(&source)
            .status()
            .unwrap();
        assert!(generated.success());

        let media = probe_one(&source).await.unwrap();
        assert!(media.needs_conversion);
        assert!(media
            .conversion_reasons
            .iter()
            .any(|reason| reason.contains("1280×720")));
        assert!(media
            .conversion_reasons
            .iter()
            .any(|reason| reason.contains("30.000fps")));
        assert!(media
            .conversion_reasons
            .iter()
            .any(|reason| reason.contains("H.264")));
        assert!(media
            .conversion_reasons
            .iter()
            .any(|reason| reason.contains("44100Hz")));
        assert!(media
            .conversion_reasons
            .iter()
            .any(|reason| reason.contains("1ch")));
    }
}
