use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rational {
    pub numerator: u64,
    pub denominator: u64,
}

impl Rational {
    pub fn value(self) -> f64 {
        if self.denominator == 0 {
            0.0
        } else {
            self.numerator as f64 / self.denominator as f64
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaInfo {
    pub duration_seconds: f64,
    pub width: u32,
    pub height: u32,
    pub fps: Rational,
    pub frame_count: u64,
    pub video_codec: String,
    pub pixel_format: String,
    pub color_space: Option<String>,
    pub audio_codec: Option<String>,
    pub sample_rate: Option<u32>,
    pub channels: Option<u32>,
    pub has_audio: bool,
    pub needs_conversion: bool,
    pub conversion_reasons: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceFingerprint {
    pub size: u64,
    pub modified_unix_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipV1 {
    pub id: String,
    pub source_path: String,
    pub source_file_name: String,
    pub fingerprint: SourceFingerprint,
    pub order: u32,
    pub band_name: String,
    pub in_frame: u64,
    pub out_frame_exclusive: u64,
    pub media: MediaInfo,
    #[serde(default)]
    pub join_with_previous: bool,
    #[serde(default)]
    pub import_error: Option<String>,
}

impl ClipV1 {
    pub fn start_seconds(&self) -> f64 {
        self.in_frame as f64 / self.media.fps.value()
    }

    pub fn end_seconds(&self) -> f64 {
        self.out_frame_exclusive as f64 / self.media.fps.value()
    }

    pub fn duration_seconds(&self) -> f64 {
        (self.end_seconds() - self.start_seconds()).max(0.0)
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CropRectNormalized {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThumbnailV1 {
    pub source_path: String,
    pub preview_path: String,
    pub source_width: u32,
    pub source_height: u32,
    pub exif_orientation: u32,
    pub crop: CropRectNormalized,
    pub zoom: f64,
    #[serde(default)]
    pub output_format: ThumbnailFormat,
}

#[derive(Debug, Default, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ThumbnailFormat {
    #[default]
    Jpg,
    Png,
}

impl ThumbnailFormat {
    pub fn extension(self) -> &'static str {
        match self {
            Self::Jpg => "jpg",
            Self::Png => "png",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectV1 {
    pub schema_version: u32,
    pub app_version: String,
    pub event_name: String,
    pub clips: Vec<ClipV1>,
    pub output_resolution: Resolution,
    #[serde(default)]
    pub output_frame_rate: FrameRate,
    pub transition_ms: u32,
    pub thumbnail: Option<ThumbnailV1>,
}

impl ProjectV1 {
    pub fn validate(&self) -> anyhow::Result<()> {
        anyhow::ensure!(self.schema_version == 1, "未対応のプロジェクト形式です。");
        anyhow::ensure!(
            matches!(
                self.app_version.as_str(),
                "0.1.0" | "0.2.0" | "0.2.1" | "0.3.0" | "0.4.0"
            ),
            "未対応のアプリバージョンです。"
        );
        anyhow::ensure!(
            self.transition_ms == 500,
            "未対応のクロスフェード設定です。"
        );
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub enum Resolution {
    #[serde(rename = "source")]
    Source,
    #[serde(rename = "1080p")]
    P1080,
    #[serde(rename = "1440p")]
    P1440,
}

impl Resolution {
    pub fn dimensions(self) -> (u32, u32) {
        match self {
            Self::Source => (1920, 1080),
            Self::P1080 => (1920, 1080),
            Self::P1440 => (2560, 1440),
        }
    }

    pub fn bitrate(self) -> u64 {
        match self {
            Self::Source => 15_000_000,
            Self::P1080 => 15_000_000,
            Self::P1440 => 30_000_000,
        }
    }

    pub fn font_size(self) -> f32 {
        match self {
            Self::Source => 72.0,
            Self::P1080 => 72.0,
            Self::P1440 => 96.0,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub enum FrameRate {
    #[serde(rename = "source")]
    Source,
    #[serde(rename = "23.976")]
    F23976,
    #[serde(rename = "24")]
    F24,
    #[serde(rename = "25")]
    F25,
    #[serde(rename = "29.97")]
    F2997,
    #[serde(rename = "30")]
    F30,
    #[serde(rename = "50")]
    F50,
    #[default]
    #[serde(rename = "59.94")]
    F5994,
    #[serde(rename = "60")]
    F60,
}

impl FrameRate {
    pub fn resolve(self, source: Option<&MediaInfo>) -> Rational {
        let (numerator, denominator) = match self {
            Self::Source => {
                return source.map(|m| m.fps).unwrap_or(Rational {
                    numerator: 30,
                    denominator: 1,
                })
            }
            Self::F23976 => (24000, 1001),
            Self::F24 => (24, 1),
            Self::F25 => (25, 1),
            Self::F2997 => (30000, 1001),
            Self::F30 => (30, 1),
            Self::F50 => (50, 1),
            Self::F5994 => (60000, 1001),
            Self::F60 => (60, 1),
        };
        Rational {
            numerator,
            denominator,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProbeResult {
    pub path: String,
    pub file_name: String,
    pub fingerprint: SourceFingerprint,
    pub media: Option<MediaInfo>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedThumbnail {
    pub source_path: String,
    pub preview_path: String,
    pub source_width: u32,
    pub source_height: u32,
    pub exif_orientation: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolStatus {
    pub ffmpeg_path: Option<String>,
    pub ffprobe_path: Option<String>,
    pub magick_path: Option<String>,
    pub font_path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RenderRequest {
    pub event_name: String,
    pub output_directory: String,
    pub resolution: Resolution,
    #[serde(default)]
    pub frame_rate: FrameRate,
    pub clips: Vec<ClipV1>,
    pub thumbnail: Option<ThumbnailV1>,
    pub overwrite: bool,
}

impl RenderRequest {
    pub fn dimensions(&self) -> (u32, u32) {
        match (self.resolution, self.clips.first()) {
            (Resolution::Source, Some(clip)) => (clip.media.width, clip.media.height),
            _ => self.resolution.dimensions(),
        }
    }
    pub fn fps(&self) -> Rational {
        self.frame_rate
            .resolve(self.clips.first().map(|c| &c.media))
    }
    pub fn bitrate(&self) -> u64 {
        if matches!(self.resolution, Resolution::Source) {
            let (w, h) = self.dimensions();
            (15_000_000 * u64::from(w) * u64::from(h) / (1920 * 1080)).clamp(4_000_000, 80_000_000)
        } else {
            self.resolution.bitrate()
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutputPaths {
    pub video: String,
    pub chapters: String,
    pub thumbnail: Option<String>,
    pub existing: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RenderStarted {
    pub job_id: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RenderProgress {
    pub job_id: String,
    pub phase: String,
    pub progress: f64,
    pub elapsed_seconds: f64,
    pub eta_seconds: Option<f64>,
    pub encoder: Option<String>,
    pub message: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RenderFinished {
    pub job_id: String,
    pub status: String,
    pub encoder: Option<String>,
    pub output_paths: Option<OutputPaths>,
    pub error: Option<String>,
}
