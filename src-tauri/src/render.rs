use std::{
    collections::HashMap,
    ffi::OsString,
    fs, io,
    path::{Path, PathBuf},
    sync::Arc,
    time::Instant,
};

use anyhow::{Context, Result};
use fontdue::{Font, FontSettings};
use tauri::{AppHandle, Emitter};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, BufReader},
    process::Command,
    sync::Mutex,
};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::{
    models::{
        ClipV1, OutputPaths, RenderFinished, RenderProgress, RenderRequest, RenderStarted,
        Resolution, TransitionPreviewRequest,
    },
    thumbnail, tools,
};

const TRANSITION_SECONDS: f64 = 0.5;
const FILTER_FONT_FILE: &str = "NotoSansJP-Black.ttf";
const OUTPUT_FPS: &str = "60000/1001";

#[derive(Clone, Default)]
pub struct RenderState {
    jobs: Arc<Mutex<HashMap<String, CancellationToken>>>,
}

impl RenderState {
    pub async fn cancel(&self, job_id: &str) -> bool {
        let jobs = self.jobs.lock().await;
        if let Some(token) = jobs.get(job_id) {
            token.cancel();
            true
        } else {
            false
        }
    }
}

#[derive(Debug, Clone)]
struct EncoderConfig {
    codec: &'static str,
    label: &'static str,
}

enum RunOutcome {
    Completed { encoder: String, paths: OutputPaths },
    Cancelled { encoder: Option<String> },
}

struct RenderArtifactsGuard {
    partials: Vec<PathBuf>,
    working_directory: PathBuf,
}

impl Drop for RenderArtifactsGuard {
    fn drop(&mut self) {
        for partial in &self.partials {
            let _ = fs::remove_file(partial);
        }
        let _ = fs::remove_dir_all(&self.working_directory);
    }
}

struct SleepGuard;

impl SleepGuard {
    fn acquire() -> Self {
        #[cfg(windows)]
        unsafe {
            use windows_sys::Win32::System::Power::{
                SetThreadExecutionState, ES_CONTINUOUS, ES_SYSTEM_REQUIRED,
            };
            SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED);
        }
        Self
    }
}

impl Drop for SleepGuard {
    fn drop(&mut self) {
        #[cfg(windows)]
        unsafe {
            use windows_sys::Win32::System::Power::{SetThreadExecutionState, ES_CONTINUOUS};
            SetThreadExecutionState(ES_CONTINUOUS);
        }
    }
}

fn safe_stem(value: &str) -> String {
    let mut result = value
        .trim()
        .chars()
        .map(|character| {
            if matches!(
                character,
                '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*'
            ) || character.is_control()
            {
                '_'
            } else {
                character
            }
        })
        .collect::<String>();
    while result.ends_with(['.', ' ']) {
        result.pop();
    }
    if result.is_empty() {
        result = "ライブ動画".to_string();
    }
    let upper = result.to_ascii_uppercase();
    if matches!(
        upper.as_str(),
        "CON"
            | "PRN"
            | "AUX"
            | "NUL"
            | "COM1"
            | "COM2"
            | "COM3"
            | "COM4"
            | "COM5"
            | "COM6"
            | "COM7"
            | "COM8"
            | "COM9"
            | "LPT1"
            | "LPT2"
            | "LPT3"
            | "LPT4"
            | "LPT5"
            | "LPT6"
            | "LPT7"
            | "LPT8"
            | "LPT9"
    ) {
        result.insert(0, '_');
    }
    result
}

pub fn output_paths_for(request: &RenderRequest) -> Result<OutputPaths> {
    let directory = Path::new(&request.output_directory);
    anyhow::ensure!(directory.is_dir(), "保存先フォルダーが見つかりません。");
    let stem = safe_stem(&request.event_name);
    let video = directory.join(format!("{stem}.mp4"));
    let chapters = directory.join(format!("{stem}_チャプター.txt"));
    let thumbnail = request
        .thumbnail
        .as_ref()
        .map(|_| directory.join(format!("{stem}_サムネイル.jpg")));
    let mut existing = Vec::new();
    for path in [&video, &chapters] {
        if path.exists() {
            existing.push(path.to_string_lossy().into_owned());
        }
    }
    if let Some(path) = &thumbnail {
        if path.exists() {
            existing.push(path.to_string_lossy().into_owned());
        }
    }
    Ok(OutputPaths {
        video: video.to_string_lossy().into_owned(),
        chapters: chapters.to_string_lossy().into_owned(),
        thumbnail: thumbnail.map(|path| path.to_string_lossy().into_owned()),
        existing,
    })
}

fn total_duration(clips: &[ClipV1]) -> f64 {
    let source: f64 = clips.iter().map(ClipV1::duration_seconds).sum();
    (source - TRANSITION_SECONDS * clips.len().saturating_sub(1) as f64).max(0.0)
}

fn validate_request(request: &RenderRequest) -> Result<OutputPaths> {
    anyhow::ensure!(
        !request.event_name.trim().is_empty(),
        "イベント名を入力してください。"
    );
    anyhow::ensure!(
        !request.clips.is_empty(),
        "動画を1本以上読み込んでください。"
    );
    anyhow::ensure!(tools::ffmpeg().is_some(), "FFmpegが見つかりません。");
    anyhow::ensure!(
        tools::font().is_some(),
        "Noto Sans JP Blackが見つかりません。"
    );
    for clip in &request.clips {
        anyhow::ensure!(
            Path::new(&clip.source_path).is_file(),
            "元動画が見つかりません: {}",
            clip.source_path
        );
        anyhow::ensure!(
            clip.media.has_audio,
            "音声のない動画は書き出せません: {}",
            clip.source_file_name
        );
        anyhow::ensure!(
            clip.media.fps.value() > 0.0,
            "フレームレートが不正です: {}",
            clip.source_file_name
        );
        anyhow::ensure!(
            clip.out_frame_exclusive > clip.in_frame,
            "トリミング範囲が不正です: {}",
            clip.band_name
        );
        anyhow::ensure!(!clip.band_name.trim().is_empty(), "バンド名が空です。");
        anyhow::ensure!(
            clip.duration_seconds() > TRANSITION_SECONDS,
            "動画が短すぎます: {}",
            clip.band_name
        );
    }
    let paths = output_paths_for(request)?;
    anyhow::ensure!(
        request.overwrite || paths.existing.is_empty(),
        "出力先に同名ファイルがあります。"
    );
    let estimated =
        ((request.resolution.bitrate() + 384_000) as f64 * total_duration(&request.clips) / 8.0
            * 1.1) as u64;
    let free = fs2::available_space(&request.output_directory)
        .context("保存先の空き容量を確認できませんでした。")?;
    anyhow::ensure!(
        free >= estimated,
        "保存先の空き容量が不足しています。必要容量の目安は{:.1}GBです。",
        estimated as f64 / 1_073_741_824.0
    );
    Ok(paths)
}

fn partial_path(path: &Path) -> PathBuf {
    let stem = path.file_stem().unwrap_or_default().to_string_lossy();
    let extension = path.extension().unwrap_or_default().to_string_lossy();
    path.with_file_name(format!("{stem}.partial.{extension}"))
}

fn working_directory(job_id: &str) -> Result<PathBuf> {
    let directory = dirs::cache_dir()
        .context("Windowsのキャッシュフォルダーが見つかりません。")?
        .join("ARTOFFICE-video-maker")
        .join(format!("render-{job_id}"));
    fs::create_dir_all(&directory).context("書き出し用キャッシュを作成できませんでした。")?;
    Ok(directory)
}

fn measured_font_size(font_path: &Path, text: &str, base: f32, max_width: f32) -> f32 {
    let Ok(bytes) = fs::read(font_path) else {
        return base;
    };
    let Ok(font) = Font::from_bytes(bytes, FontSettings::default()) else {
        return base;
    };
    let mut size = base;
    while size > base * 0.5 {
        let width: f32 = text
            .chars()
            .map(|character| font.metrics(character, size).advance_width)
            .sum();
        if width <= max_width {
            return size;
        }
        size -= 2.0;
    }
    size
}

fn build_filter_graph(
    clips: &[ClipV1],
    resolution: Resolution,
    dimensions: (u32, u32),
    font_path: &Path,
    working: &Path,
) -> Result<PathBuf> {
    let (width, height) = dimensions;
    let working_font = working.join(FILTER_FONT_FILE);
    fs::copy(font_path, &working_font).context("書き出し用フォントを準備できませんでした。")?;
    let escaped_font = FILTER_FONT_FILE;
    let base_font_size = if dimensions == resolution.dimensions() {
        resolution.font_size()
    } else {
        height as f32 / 15.0
    };
    let mut graph = String::new();
    for (index, clip) in clips.iter().enumerate() {
        let title_path = working.join(format!("title-{index}.txt"));
        fs::write(&title_path, clip.band_name.as_bytes())
            .context("バンド名の一時ファイルを作成できませんでした。")?;
        let escaped_title = format!("title-{index}.txt");
        let font_size = measured_font_size(
            font_path,
            &clip.band_name,
            base_font_size,
            width as f32 * 0.85,
        );
        graph.push_str(&format!(
            "[{index}:v]trim=start={:.9}:end={:.9},setpts=PTS-STARTPTS,yadif=deint=interlaced,fps={OUTPUT_FPS},scale={width}:{height}:force_original_aspect_ratio=decrease:flags=lanczos,pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,format=yuv420p,settb=AVTB,drawtext=fontfile='{escaped_font}':textfile='{escaped_title}':fontcolor=white:fontsize={font_size:.2}:x=w*0.05:y=h-text_h-h*0.05:alpha='if(lt(t,0.5),t/0.5,if(lt(t,4.5),1,if(lt(t,5),(5-t)/0.5,0)))':enable='between(t,0,5)'[v{index}];\n",
            clip.start_seconds(),
            clip.end_seconds(),
        ));
        graph.push_str(&format!(
            "[{index}:a]atrim=start={:.9}:end={:.9},asetpts=PTS-STARTPTS,aresample=48000:async=0:first_pts=0,aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo[a{index}];\n",
            clip.start_seconds(),
            clip.end_seconds(),
        ));
    }

    let (video_output, audio_output) = if clips.len() == 1 {
        ("v0".to_string(), "a0".to_string())
    } else {
        let mut accumulated = clips[0].duration_seconds();
        let mut previous_video = "v0".to_string();
        let mut previous_audio = "a0".to_string();
        for (index, clip) in clips.iter().enumerate().skip(1) {
            let output_video = format!("vx{index}");
            let output_audio = format!("ax{index}");
            let offset = (accumulated - TRANSITION_SECONDS).max(0.0);
            graph.push_str(&format!(
                "[{previous_video}][v{index}]xfade=transition=fade:duration={TRANSITION_SECONDS}:offset={offset:.9}[{output_video}];\n"
            ));
            graph.push_str(&format!(
                "[{previous_audio}][a{index}]acrossfade=d={TRANSITION_SECONDS}:c1=tri:c2=tri[{output_audio}];\n"
            ));
            accumulated += clip.duration_seconds() - TRANSITION_SECONDS;
            previous_video = output_video;
            previous_audio = output_audio;
        }
        (previous_video, previous_audio)
    };
    graph.push_str(&format!(
        "[{video_output}]setparams=range=tv:color_primaries=bt709:color_trc=bt709:colorspace=bt709[vout];\n[{audio_output}]anull[aout]\n"
    ));
    let graph_path = working.join("filter-graph.txt");
    fs::write(&graph_path, graph.as_bytes()).context("FFmpegフィルターを作成できませんでした。")?;
    Ok(graph_path)
}

fn encoder_args(
    config: &EncoderConfig,
    resolution: Resolution,
    bitrate_override: Option<u64>,
) -> Vec<OsString> {
    let bitrate = bitrate_override.unwrap_or_else(|| resolution.bitrate());
    let maxrate = bitrate * 7 / 5;
    let bufsize = bitrate * 2;
    let mut args = Vec::<OsString>::new();
    macro_rules! push {
        ($value:expr) => {
            args.push(OsString::from($value))
        };
    }
    match config.codec {
        "h264_nvenc" => {
            push!("-preset");
            push!("p5");
            push!("-rc");
            push!("vbr");
        }
        "h264_qsv" => {
            push!("-preset");
            push!("medium");
        }
        "h264_amf" => {
            push!("-quality");
            push!("quality");
            push!("-rc");
            push!("vbr_peak");
        }
        "libx264" => {
            push!("-preset");
            push!("medium");
            push!("-sc_threshold");
            push!("0");
        }
        _ => {}
    }
    push!("-b:v");
    push!(bitrate.to_string());
    if config.codec != "h264_mf" {
        push!("-maxrate");
        push!(maxrate.to_string());
        push!("-bufsize");
        push!(bufsize.to_string());
        push!("-profile:v");
        push!("high");
        push!("-bf");
        push!("2");
    } else {
        // h264_mf accepts the numeric FFmpeg profile identifier, but not the
        // human-readable "high" value accepted by the other encoders.
        push!("-profile:v");
        push!("100");
    }
    push!("-g");
    push!("30");
    args
}

async fn encoder_available(ffmpeg: &Path, config: &EncoderConfig) -> bool {
    let mut command = Command::new(ffmpeg);
    tools::hide_console(&mut command);
    command
        .arg("-hide_banner")
        .arg("-loglevel")
        .arg("error")
        .arg("-f")
        .arg("lavfi")
        .arg("-i")
        .arg("color=c=black:s=640x360:r=60000/1001:d=0.2")
        .arg("-frames:v")
        .arg("6")
        .arg("-pix_fmt")
        .arg("yuv420p")
        .arg("-c:v")
        .arg(config.codec);
    command.args(encoder_args(config, Resolution::P1080, Some(2_000_000)));
    command.arg("-f").arg("null").arg("-");
    command
        .output()
        .await
        .is_ok_and(|output| output.status.success())
}

async fn choose_encoder(ffmpeg: &Path, cancellation: &CancellationToken) -> Result<EncoderConfig> {
    let candidates = [
        EncoderConfig {
            codec: "h264_nvenc",
            label: "NVIDIA NVENC",
        },
        EncoderConfig {
            codec: "h264_qsv",
            label: "Intel Quick Sync",
        },
        EncoderConfig {
            codec: "h264_amf",
            label: "AMD AMF",
        },
        EncoderConfig {
            codec: "h264_mf",
            label: "Windows Media Foundation",
        },
        EncoderConfig {
            codec: "libx264",
            label: "CPU（libx264）",
        },
    ];
    for candidate in candidates {
        if cancellation.is_cancelled() {
            anyhow::bail!("cancelled");
        }
        if encoder_available(ffmpeg, &candidate).await {
            return Ok(candidate);
        }
    }
    anyhow::bail!("利用可能なH.264エンコーダーがありません。")
}

fn chapter_text(clips: &[ClipV1]) -> String {
    let mut cursor = 0.0_f64;
    let mut rows = Vec::with_capacity(clips.len());
    for (index, clip) in clips.iter().enumerate() {
        let seconds = cursor.floor().max(0.0) as u64;
        let hours = seconds / 3600;
        let minutes = (seconds % 3600) / 60;
        let remainder = seconds % 60;
        rows.push(format!(
            "{hours}:{minutes:02}:{remainder:02} {}",
            clip.band_name
        ));
        cursor += clip.duration_seconds();
        if index + 1 < clips.len() {
            cursor -= TRANSITION_SECONDS;
        }
    }
    format!("{}\r\n", rows.join("\r\n"))
}

fn emit_progress(app: &AppHandle, payload: RenderProgress) {
    let _ = app.emit("render-progress", payload);
}

struct FfmpegExecution<'a> {
    app: &'a AppHandle,
    job_id: &'a str,
    request: &'a RenderRequest,
    encoder: &'a EncoderConfig,
    ffmpeg: &'a Path,
    graph: &'a Path,
    output: &'a Path,
    cancellation: &'a CancellationToken,
}

async fn execute_ffmpeg(execution: FfmpegExecution<'_>) -> Result<bool> {
    let FfmpegExecution {
        app,
        job_id,
        request,
        encoder,
        ffmpeg,
        graph,
        output,
        cancellation,
    } = execution;
    let total = total_duration(&request.clips);
    let started = Instant::now();
    let mut command = Command::new(ffmpeg);
    tools::hide_console(&mut command);
    if let Some(working) = graph.parent() {
        command.current_dir(working);
    }
    command
        .arg("-hide_banner")
        .arg("-loglevel")
        .arg("warning")
        .arg("-y");
    for clip in &request.clips {
        command.arg("-i").arg(&clip.source_path);
    }
    command
        .arg("-filter_complex_script")
        .arg(graph)
        .arg("-map")
        .arg("[vout]")
        .arg("-map")
        .arg("[aout]")
        .arg("-c:v")
        .arg(encoder.codec)
        .args(encoder_args(encoder, request.resolution, None))
        .arg("-r")
        .arg(OUTPUT_FPS)
        .arg("-pix_fmt")
        .arg("yuv420p")
        .arg("-color_primaries")
        .arg("bt709")
        .arg("-color_trc")
        .arg("bt709")
        .arg("-colorspace")
        .arg("bt709")
        .arg("-c:a")
        .arg("aac")
        .arg("-b:a")
        .arg("384k")
        .arg("-ar")
        .arg("48000")
        .arg("-ac")
        .arg("2")
        .arg("-movflags")
        .arg("+faststart")
        .arg("-progress")
        .arg("pipe:1")
        .arg("-nostats")
        .arg(output)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);

    let mut child = command.spawn().context("FFmpegを起動できませんでした。")?;
    let stdout = child
        .stdout
        .take()
        .context("FFmpegの進捗を取得できませんでした。")?;
    let stderr = child
        .stderr
        .take()
        .context("FFmpegのエラー出力を取得できませんでした。")?;
    let stderr_task = tokio::spawn(async move {
        let mut bytes = Vec::new();
        let mut reader = BufReader::new(stderr);
        let _ = reader.read_to_end(&mut bytes).await;
        String::from_utf8_lossy(&bytes).into_owned()
    });
    let mut lines = BufReader::new(stdout).lines();
    loop {
        tokio::select! {
            _ = cancellation.cancelled() => {
                let _ = child.kill().await;
                let _ = child.wait().await;
                let _ = stderr_task.await;
                return Ok(false);
            }
            line = lines.next_line() => {
                match line.context("FFmpegの進捗を読み取れませんでした。")? {
                    Some(line) => {
                        if let Some(value) = line.strip_prefix("out_time_us=").and_then(|value| value.parse::<u64>().ok()) {
                            let rendered_seconds = value as f64 / 1_000_000.0;
                            let progress = if total > 0.0 { (rendered_seconds / total).clamp(0.0, 0.999) } else { 0.0 };
                            let elapsed = started.elapsed().as_secs_f64();
                            let eta = if rendered_seconds > 0.1 {
                                Some(((total - rendered_seconds).max(0.0) * elapsed / rendered_seconds).max(0.0))
                            } else { None };
                            emit_progress(app, RenderProgress {
                                job_id: job_id.to_string(),
                                phase: "rendering".to_string(),
                                progress,
                                elapsed_seconds: elapsed,
                                eta_seconds: eta,
                                encoder: Some(encoder.label.to_string()),
                                message: "完成動画を書き出しています。".to_string(),
                            });
                        }
                    }
                    None => break,
                }
            }
        }
    }
    let status = child
        .wait()
        .await
        .context("FFmpegの終了状態を取得できませんでした。")?;
    let stderr_text = stderr_task
        .await
        .unwrap_or_else(|_| "FFmpegのエラーを取得できませんでした。".to_string());
    anyhow::ensure!(
        status.success(),
        "FFmpegの書き出しに失敗しました。\n{}",
        stderr_text.trim()
    );
    emit_progress(
        app,
        RenderProgress {
            job_id: job_id.to_string(),
            phase: "finalizing".to_string(),
            progress: 0.999,
            elapsed_seconds: started.elapsed().as_secs_f64(),
            eta_seconds: Some(0.0),
            encoder: Some(encoder.label.to_string()),
            message: "出力ファイルを確定しています。".to_string(),
        },
    );
    Ok(true)
}

#[cfg(windows)]
fn replace_file(source: &Path, destination: &Path) -> io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };
    let source_wide = source
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect::<Vec<_>>();
    let destination_wide = destination
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect::<Vec<_>>();
    let result = unsafe {
        MoveFileExW(
            source_wide.as_ptr(),
            destination_wide.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if result == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(not(windows))]
fn replace_file(source: &Path, destination: &Path) -> io::Result<()> {
    if destination.exists() {
        fs::remove_file(destination)?;
    }
    fs::rename(source, destination)
}

fn backup_path(path: &Path, job_id: &str) -> PathBuf {
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    path.with_file_name(format!("{name}.aov-backup-{job_id}"))
}

fn commit_outputs(outputs: &[(&Path, &Path)], job_id: &str) -> Result<()> {
    let mut backups = Vec::<(PathBuf, PathBuf)>::new();

    for (_, destination) in outputs {
        if destination.exists() {
            let backup = backup_path(destination, job_id);
            let _ = fs::remove_file(&backup);
            if let Err(error) = fs::rename(destination, &backup) {
                for (original, staged) in backups.iter().rev() {
                    let _ = replace_file(staged, original);
                }
                return Err(error).context("既存の出力ファイルを一時退避できませんでした。");
            }
            backups.push((destination.to_path_buf(), backup));
        }
    }

    let mut installed = Vec::<PathBuf>::new();
    for (partial, destination) in outputs {
        if let Err(error) = replace_file(partial, destination) {
            for path in installed.iter().rev() {
                let _ = fs::remove_file(path);
            }
            let _ = fs::remove_file(destination);
            for (original, staged) in backups.iter().rev() {
                let _ = replace_file(staged, original);
            }
            return Err(error).context("完成した出力ファイルを確定できませんでした。");
        }
        installed.push(destination.to_path_buf());
    }

    for (_, backup) in backups {
        let _ = fs::remove_file(backup);
    }
    Ok(())
}

async fn run_job(
    app: AppHandle,
    job_id: String,
    request: RenderRequest,
    cancellation: CancellationToken,
) -> Result<RunOutcome> {
    let _sleep_guard = SleepGuard::acquire();
    let paths = validate_request(&request)?;
    let ffmpeg = tools::ffmpeg().context("FFmpegが見つかりません。")?;
    let font = tools::font().context("Noto Sans JP Blackが見つかりません。")?;
    let working = working_directory(&job_id)?;
    let final_video = PathBuf::from(&paths.video);
    let final_chapters = PathBuf::from(&paths.chapters);
    let final_thumbnail = paths.thumbnail.as_ref().map(PathBuf::from);
    let partial_video = partial_path(&final_video);
    let partial_chapters = partial_path(&final_chapters);
    let partial_thumbnail = final_thumbnail.as_ref().map(|path| partial_path(path));
    let mut partials = vec![partial_video.clone(), partial_chapters.clone()];
    if let Some(path) = &partial_thumbnail {
        partials.push(path.clone());
    }
    let _artifact_guard = RenderArtifactsGuard {
        partials,
        working_directory: working.clone(),
    };
    for partial in [&partial_video, &partial_chapters] {
        let _ = fs::remove_file(partial);
    }
    if let Some(path) = &partial_thumbnail {
        let _ = fs::remove_file(path);
    }

    emit_progress(
        &app,
        RenderProgress {
            job_id: job_id.clone(),
            phase: "preparing".to_string(),
            progress: 0.0,
            elapsed_seconds: 0.0,
            eta_seconds: None,
            encoder: None,
            message: "GPUエンコーダーを確認しています。".to_string(),
        },
    );
    let encoder = match choose_encoder(&ffmpeg, &cancellation).await {
        Ok(encoder) => encoder,
        Err(error) if error.to_string() == "cancelled" => {
            return Ok(RunOutcome::Cancelled { encoder: None });
        }
        Err(error) => return Err(error),
    };
    if cancellation.is_cancelled() {
        return Ok(RunOutcome::Cancelled {
            encoder: Some(encoder.label.to_string()),
        });
    }

    fs::write(&partial_chapters, chapter_text(&request.clips).as_bytes())
        .context("チャプターテキストを作成できませんでした。")?;
    if let (Some(model), Some(destination)) = (&request.thumbnail, &partial_thumbnail) {
        emit_progress(
            &app,
            RenderProgress {
                job_id: job_id.clone(),
                phase: "preparing".to_string(),
                progress: 0.0,
                elapsed_seconds: 0.0,
                eta_seconds: None,
                encoder: Some(encoder.label.to_string()),
                message: "サムネイルを作成しています。".to_string(),
            },
        );
        thumbnail::export(model, destination).await?;
    }
    if cancellation.is_cancelled() {
        return Ok(RunOutcome::Cancelled {
            encoder: Some(encoder.label.to_string()),
        });
    }

    let graph = build_filter_graph(
        &request.clips,
        request.resolution,
        request.resolution.dimensions(),
        &font,
        &working,
    )?;
    let completed = execute_ffmpeg(FfmpegExecution {
        app: &app,
        job_id: &job_id,
        request: &request,
        encoder: &encoder,
        ffmpeg: &ffmpeg,
        graph: &graph,
        output: &partial_video,
        cancellation: &cancellation,
    })
    .await?;
    if !completed {
        return Ok(RunOutcome::Cancelled {
            encoder: Some(encoder.label.to_string()),
        });
    }

    let mut outputs = vec![
        (partial_video.as_path(), final_video.as_path()),
        (partial_chapters.as_path(), final_chapters.as_path()),
    ];
    if let (Some(partial), Some(final_path)) = (&partial_thumbnail, &final_thumbnail) {
        outputs.push((partial.as_path(), final_path.as_path()));
    }
    commit_outputs(&outputs, &job_id)?;
    Ok(RunOutcome::Completed {
        encoder: encoder.label.to_string(),
        paths,
    })
}

pub async fn start(
    app: AppHandle,
    state: RenderState,
    request: RenderRequest,
) -> Result<RenderStarted> {
    validate_request(&request)?;
    let job_id = Uuid::new_v4().to_string();
    let cancellation = CancellationToken::new();
    {
        let mut jobs = state.jobs.lock().await;
        anyhow::ensure!(jobs.is_empty(), "別の書き出しが進行中です。");
        jobs.insert(job_id.clone(), cancellation.clone());
    }
    let result_id = job_id.clone();
    let state_for_task = state.clone();
    tauri::async_runtime::spawn(async move {
        let result = run_job(app.clone(), result_id.clone(), request, cancellation).await;
        let payload = match result {
            Ok(RunOutcome::Completed { encoder, paths }) => RenderFinished {
                job_id: result_id.clone(),
                status: "completed".to_string(),
                encoder: Some(encoder),
                output_paths: Some(paths),
                error: None,
            },
            Ok(RunOutcome::Cancelled { encoder }) => RenderFinished {
                job_id: result_id.clone(),
                status: "cancelled".to_string(),
                encoder,
                output_paths: None,
                error: None,
            },
            Err(error) => RenderFinished {
                job_id: result_id.clone(),
                status: "failed".to_string(),
                encoder: None,
                output_paths: None,
                error: Some(format!("{error:#}")),
            },
        };
        let _ = app.emit("render-finished", payload);
        state_for_task.jobs.lock().await.remove(&result_id);
    });
    Ok(RenderStarted { job_id })
}

pub async fn transition_preview(request: TransitionPreviewRequest) -> Result<String> {
    let ffmpeg = tools::ffmpeg().context("FFmpegが見つかりません。")?;
    let font = tools::font().context("Noto Sans JP Blackが見つかりません。")?;
    let cancellation = CancellationToken::new();
    let encoder = choose_encoder(&ffmpeg, &cancellation).await?;
    let id = Uuid::new_v4().to_string();
    let working = working_directory(&format!("preview-{id}"))?;
    let mut current = request.current;
    let mut next = request.next;
    let current_fps = current.media.fps.value();
    let next_fps = next.media.fps.value();
    current.in_frame = current
        .out_frame_exclusive
        .saturating_sub((2.0 * current_fps).round() as u64)
        .max(current.in_frame);
    next.out_frame_exclusive =
        (next.in_frame + (3.0 * next_fps).round() as u64).min(next.out_frame_exclusive);
    let clips = vec![current, next];
    let graph = build_filter_graph(&clips, Resolution::P1080, (1280, 720), &font, &working)?;
    let directory = dirs::cache_dir()
        .context("Windowsのキャッシュフォルダーが見つかりません。")?
        .join("ARTOFFICE-video-maker")
        .join("transition-previews");
    fs::create_dir_all(&directory)?;
    let output_path = directory.join(format!("transition-{id}.mp4"));
    let mut command = Command::new(&ffmpeg);
    tools::hide_console(&mut command);
    command.current_dir(&working);
    command
        .arg("-hide_banner")
        .arg("-loglevel")
        .arg("error")
        .arg("-y");
    for clip in &clips {
        command.arg("-i").arg(&clip.source_path);
    }
    command
        .arg("-filter_complex_script")
        .arg(&graph)
        .arg("-map")
        .arg("[vout]")
        .arg("-map")
        .arg("[aout]")
        .arg("-c:v")
        .arg(encoder.codec)
        .args(encoder_args(&encoder, Resolution::P1080, Some(5_000_000)))
        .arg("-r")
        .arg(OUTPUT_FPS)
        .arg("-pix_fmt")
        .arg("yuv420p")
        .arg("-c:a")
        .arg("aac")
        .arg("-b:a")
        .arg("192k")
        .arg("-movflags")
        .arg("+faststart")
        .arg(&output_path);
    let result = command
        .output()
        .await
        .context("つなぎ目プレビューを作成できませんでした。")?;
    let _ = fs::remove_dir_all(&working);
    anyhow::ensure!(
        result.status.success(),
        "つなぎ目プレビューの作成に失敗しました: {}",
        String::from_utf8_lossy(&result.stderr).trim()
    );
    Ok(output_path.to_string_lossy().into_owned())
}

pub fn cleanup_cache() {
    if let Some(cache) = dirs::cache_dir() {
        let root = cache.join("ARTOFFICE-video-maker");
        if let Ok(entries) = fs::read_dir(&root) {
            for path in entries.filter_map(|entry| entry.ok().map(|entry| entry.path())) {
                let name = path.file_name().unwrap_or_default().to_string_lossy();
                if name.starts_with("render-") || name == "transition-previews" {
                    let _ = fs::remove_dir_all(path);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::{
        env, fs,
        path::{Path, PathBuf},
        process::Command as StdCommand,
    };

    use super::{
        build_filter_graph, chapter_text, choose_encoder, encoder_args, safe_stem, total_duration,
        FILTER_FONT_FILE, OUTPUT_FPS,
    };
    use crate::models::{ClipV1, MediaInfo, ProjectV1, Rational, Resolution, SourceFingerprint};
    use crate::{media, project, tools};
    use tokio_util::sync::CancellationToken;

    fn clip(name: &str, seconds: f64) -> ClipV1 {
        let fps = Rational {
            numerator: 60000,
            denominator: 1001,
        };
        ClipV1 {
            id: name.to_string(),
            source_path: String::new(),
            source_file_name: String::new(),
            fingerprint: SourceFingerprint {
                size: 0,
                modified_unix_ms: 0,
            },
            order: 1,
            band_name: name.to_string(),
            in_frame: 0,
            out_frame_exclusive: (seconds * fps.value()).round() as u64,
            media: MediaInfo {
                duration_seconds: seconds,
                width: 1920,
                height: 1080,
                fps,
                frame_count: (seconds * fps.value()).round() as u64,
                video_codec: "h264".to_string(),
                pixel_format: "yuv420p".to_string(),
                color_space: Some("bt709".to_string()),
                audio_codec: Some("aac".to_string()),
                sample_rate: Some(48000),
                channels: Some(2),
                has_audio: true,
                needs_conversion: false,
                conversion_reasons: Vec::new(),
            },
            import_error: None,
        }
    }

    #[test]
    fn chapters_account_for_crossfade_and_floor_seconds() {
        let clips = vec![clip("MOSHIMO", 20.8), clip("Mrs. GREEN APPLE", 30.2)];
        assert_eq!(
            chapter_text(&clips),
            "0:00:00 MOSHIMO\r\n0:00:20 Mrs. GREEN APPLE\r\n"
        );
        assert!((total_duration(&clips) - 50.5).abs() < 0.05);
    }

    #[test]
    fn sanitizes_windows_file_names() {
        assert_eq!(safe_stem("8月:ライブ?"), "8月_ライブ_");
        assert_eq!(safe_stem("CON"), "_CON");
    }

    #[test]
    fn filter_graph_uses_ascii_relative_title_assets() {
        let Some(source_font) = tools::font() else {
            return;
        };
        let temp = tempfile::tempdir().unwrap();
        let non_ascii_directory = temp.path().join("日本語のフォルダー");
        fs::create_dir_all(&non_ascii_directory).unwrap();
        let non_ascii_font = non_ascii_directory.join(FILTER_FONT_FILE);
        fs::copy(&source_font, &non_ascii_font).unwrap();
        let working = temp.path().join("working");
        fs::create_dir_all(&working).unwrap();

        let graph = build_filter_graph(
            &[clip("サカナクション 1", 3.0)],
            Resolution::P1080,
            (640, 360),
            &non_ascii_font,
            &working,
        )
        .unwrap();
        let contents = fs::read_to_string(graph).unwrap();

        assert!(contents.contains("fontfile='NotoSansJP-Black.ttf'"));
        assert!(contents.contains("textfile='title-0.txt'"));
        assert!(!contents.contains("日本語のフォルダー"));
        assert_eq!(
            fs::read(working.join(FILTER_FONT_FILE)).unwrap(),
            fs::read(non_ascii_font).unwrap()
        );
        assert_eq!(
            fs::read_to_string(working.join("title-0.txt")).unwrap(),
            "サカナクション 1"
        );
    }

    #[tokio::test]
    async fn ffmpeg_filter_graph_smoke_test() {
        let Some(ffmpeg) = tools::ffmpeg() else {
            return;
        };
        let Some(font) = tools::font() else { return };
        let temp = tempfile::tempdir().unwrap();
        let mut clips = Vec::new();
        for (index, (color, frequency, name)) in [("red", 440, "バンドA"), ("blue", 660, "Band_B")]
            .into_iter()
            .enumerate()
        {
            let source = temp.path().join(format!("{}_{}.mp4", index + 1, name));
            let status = StdCommand::new(&ffmpeg)
                .args([
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-y",
                    "-f",
                    "lavfi",
                    "-i",
                ])
                .arg(format!("color=c={color}:s=640x360:r=60000/1001:d=3"))
                .args(["-f", "lavfi", "-i"])
                .arg(format!(
                    "sine=frequency={frequency}:sample_rate=48000:duration=3"
                ))
                .args(["-shortest", "-c:v", "mpeg4", "-q:v", "5", "-c:a", "aac"])
                .arg(&source)
                .status()
                .unwrap();
            assert!(status.success());
            let mut value = clip(name, 3.0);
            value.source_path = source.to_string_lossy().into_owned();
            value.source_file_name = source.file_name().unwrap().to_string_lossy().into_owned();
            clips.push(value);
        }

        let graph =
            build_filter_graph(&clips, Resolution::P1080, (640, 360), &font, temp.path()).unwrap();
        let encoder = choose_encoder(&ffmpeg, &CancellationToken::new())
            .await
            .unwrap();
        let output = temp.path().join("smoke.mp4");
        let mut command = StdCommand::new(&ffmpeg);
        command.current_dir(temp.path());
        command.args(["-hide_banner", "-loglevel", "error", "-y"]);
        for clip in &clips {
            command.arg("-i").arg(&clip.source_path);
        }
        command
            .arg("-filter_complex_script")
            .arg(&graph)
            .args(["-map", "[vout]", "-map", "[aout]", "-c:v", encoder.codec])
            .args(encoder_args(&encoder, Resolution::P1080, Some(2_000_000)))
            .args([
                "-r",
                "60000/1001",
                "-pix_fmt",
                "yuv420p",
                "-c:a",
                "aac",
                "-b:a",
                "192k",
                "-movflags",
                "+faststart",
            ])
            .arg(&output);
        let result = command.output().unwrap();
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
        assert!(output.metadata().unwrap().len() > 10_000);
    }

    #[tokio::test]
    #[ignore = "slow full-resolution FFmpeg output contract test"]
    async fn ffmpeg_output_resolution_contract_test() {
        let Some(ffmpeg) = tools::ffmpeg() else {
            return;
        };
        let Some(ffprobe) = tools::ffprobe() else {
            return;
        };
        let Some(font) = tools::font() else { return };
        let temp = tempfile::tempdir().unwrap();
        let mut clips = Vec::new();
        for (index, (color, frequency, name)) in [("red", 440, "バンドA"), ("blue", 660, "バンドB")]
            .into_iter()
            .enumerate()
        {
            let source = temp.path().join(format!("{}_{}.mp4", index + 1, name));
            let status = StdCommand::new(&ffmpeg)
                .args([
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-y",
                    "-f",
                    "lavfi",
                    "-i",
                ])
                .arg(format!("color=c={color}:s=640x360:r=60000/1001:d=1"))
                .args(["-f", "lavfi", "-i"])
                .arg(format!(
                    "sine=frequency={frequency}:sample_rate=48000:duration=1"
                ))
                .args(["-shortest", "-c:v", "mpeg4", "-q:v", "5", "-c:a", "aac"])
                .arg(&source)
                .status()
                .unwrap();
            assert!(status.success());
            let mut value = clip(name, 1.0);
            value.source_path = source.to_string_lossy().into_owned();
            value.source_file_name = source.file_name().unwrap().to_string_lossy().into_owned();
            clips.push(value);
        }

        let encoder = choose_encoder(&ffmpeg, &CancellationToken::new())
            .await
            .unwrap();
        for (resolution, stem) in [
            (Resolution::P1080, "contract-1080p"),
            (Resolution::P1440, "contract-1440p"),
        ] {
            let working = temp.path().join(stem);
            fs::create_dir_all(&working).unwrap();
            let graph =
                build_filter_graph(&clips, resolution, resolution.dimensions(), &font, &working)
                    .unwrap();
            let output = temp.path().join(format!("{stem}.mp4"));
            let mut command = StdCommand::new(&ffmpeg);
            command.current_dir(&working);
            command.args(["-hide_banner", "-loglevel", "error", "-y"]);
            for clip in &clips {
                command.arg("-i").arg(&clip.source_path);
            }
            command
                .arg("-filter_complex_script")
                .arg(&graph)
                .args(["-map", "[vout]", "-map", "[aout]", "-c:v", encoder.codec])
                .args(encoder_args(&encoder, resolution, None))
                .args([
                    "-r",
                    OUTPUT_FPS,
                    "-pix_fmt",
                    "yuv420p",
                    "-color_primaries",
                    "bt709",
                    "-color_trc",
                    "bt709",
                    "-colorspace",
                    "bt709",
                    "-c:a",
                    "aac",
                    "-b:a",
                    "384k",
                    "-ar",
                    "48000",
                    "-ac",
                    "2",
                    "-movflags",
                    "+faststart",
                ])
                .arg(&output);
            let rendered = command.output().unwrap();
            assert!(
                rendered.status.success(),
                "{}",
                String::from_utf8_lossy(&rendered.stderr)
            );

            let probe = StdCommand::new(&ffprobe)
                .args([
                    "-v",
                    "error",
                    "-show_entries",
                    "stream=codec_type,codec_name,profile,width,height,pix_fmt,avg_frame_rate,sample_rate,channels,color_space,color_transfer,color_primaries",
                    "-of",
                    "json",
                ])
                .arg(&output)
                .output()
                .unwrap();
            assert!(probe.status.success());
            let metadata: serde_json::Value = serde_json::from_slice(&probe.stdout).unwrap();
            let streams = metadata["streams"].as_array().unwrap();
            let video = streams
                .iter()
                .find(|stream| stream["codec_type"] == "video")
                .unwrap();
            let audio = streams
                .iter()
                .find(|stream| stream["codec_type"] == "audio")
                .unwrap();
            let (expected_width, expected_height) = resolution.dimensions();
            assert_eq!(video["codec_name"], "h264");
            assert_eq!(video["profile"], "High");
            assert_eq!(video["width"], expected_width);
            assert_eq!(video["height"], expected_height);
            assert_eq!(video["pix_fmt"], "yuv420p");
            assert_eq!(video["avg_frame_rate"], OUTPUT_FPS);
            assert_eq!(video["color_space"], "bt709");
            assert_eq!(video["color_transfer"], "bt709");
            assert_eq!(video["color_primaries"], "bt709");
            assert_eq!(audio["codec_name"], "aac");
            assert_eq!(audio["sample_rate"], "48000");
            assert_eq!(audio["channels"], 2);
        }
        println!("encoder={}", encoder.label);
    }

    fn band_name_from_path(path: &Path) -> String {
        path.file_stem()
            .and_then(|value| value.to_str())
            .and_then(|value| value.split_once('_'))
            .map(|(_, band_name)| band_name.to_string())
            .expect("acceptance file name must use order_band-name.mp4")
    }

    #[tokio::test]
    #[ignore = "requires user-supplied real MP4 files"]
    async fn real_media_acceptance_test() {
        let source_paths = [
            env::var("AOV_ACCEPTANCE_CLIP_1").expect("AOV_ACCEPTANCE_CLIP_1 is required"),
            env::var("AOV_ACCEPTANCE_CLIP_2").expect("AOV_ACCEPTANCE_CLIP_2 is required"),
        ];
        let event_name =
            env::var("AOV_ACCEPTANCE_EVENT").expect("AOV_ACCEPTANCE_EVENT is required");
        let output_directory = PathBuf::from(
            env::var("AOV_ACCEPTANCE_OUTPUT_DIR").expect("AOV_ACCEPTANCE_OUTPUT_DIR is required"),
        );
        fs::create_dir_all(&output_directory).unwrap();

        let probes = media::probe_paths(source_paths.to_vec()).await;
        assert_eq!(probes.len(), 2);
        let mut clips = Vec::with_capacity(2);
        for (index, probe) in probes.into_iter().enumerate() {
            assert!(probe.error.is_none(), "{}", probe.error.unwrap_or_default());
            let media = probe.media.expect("media metadata is required");
            assert_eq!((media.width, media.height), (1920, 1080));
            assert!((media.fps.value() - 60000.0 / 1001.0).abs() < 0.001);
            assert_eq!(media.video_codec, "h264");
            assert_eq!(media.pixel_format, "yuv420p");
            assert_eq!(media.audio_codec.as_deref(), Some("aac"));
            assert_eq!(media.sample_rate, Some(48_000));
            assert_eq!(media.channels, Some(2));
            assert!(!media.needs_conversion);

            let in_frame = if index == 0 { 300 } else { 600 };
            let segment_frames = (8.0 * media.fps.value()).round() as u64;
            let out_frame_exclusive = in_frame + segment_frames;
            assert!(out_frame_exclusive < media.frame_count);
            let source_path = PathBuf::from(&probe.path);
            clips.push(ClipV1 {
                id: format!("acceptance-{}", index + 1),
                source_path: probe.path,
                source_file_name: probe.file_name,
                fingerprint: probe.fingerprint,
                order: (index + 1) as u32,
                band_name: band_name_from_path(&source_path),
                in_frame,
                out_frame_exclusive,
                media,
                import_error: None,
            });
        }

        assert_eq!(clips[0].band_name, "SHISHAMO 1");
        assert_eq!(clips[1].band_name, "aiko 2");
        let project_model = ProjectV1 {
            schema_version: 1,
            app_version: "0.1.0".to_string(),
            event_name: event_name.clone(),
            clips: clips.clone(),
            output_resolution: Resolution::P1080,
            transition_ms: 500,
            thumbnail: None,
        };
        let project_path = output_directory.join(format!("{event_name}.aovproj"));
        project::write(project_path.to_str().unwrap(), &project_model).unwrap();
        let reloaded = project::read(project_path.to_str().unwrap()).unwrap();
        assert_eq!(reloaded.event_name, event_name);
        assert_eq!(reloaded.clips.len(), 2);

        let ffmpeg = tools::ffmpeg().expect("FFmpeg is required");
        let ffprobe = tools::ffprobe().expect("FFprobe is required");
        let font = tools::font().expect("Noto Sans JP Black is required");
        let working = output_directory.join("working");
        fs::create_dir_all(&working).unwrap();
        let graph = build_filter_graph(
            &clips,
            Resolution::P1080,
            Resolution::P1080.dimensions(),
            &font,
            &working,
        )
        .unwrap();
        let encoder = choose_encoder(&ffmpeg, &CancellationToken::new())
            .await
            .unwrap();
        let output = output_directory.join(format!("{event_name}.mp4"));
        let chapters_path = output_directory.join(format!("{event_name}_チャプター.txt"));
        fs::write(&chapters_path, chapter_text(&clips).as_bytes()).unwrap();

        let mut command = StdCommand::new(&ffmpeg);
        command.current_dir(&working);
        command.args(["-hide_banner", "-loglevel", "warning", "-y"]);
        for clip in &clips {
            command.arg("-i").arg(&clip.source_path);
        }
        command
            .arg("-filter_complex_script")
            .arg(&graph)
            .args(["-map", "[vout]", "-map", "[aout]", "-c:v", encoder.codec])
            .args(encoder_args(&encoder, Resolution::P1080, None))
            .args([
                "-r",
                OUTPUT_FPS,
                "-pix_fmt",
                "yuv420p",
                "-color_primaries",
                "bt709",
                "-color_trc",
                "bt709",
                "-colorspace",
                "bt709",
                "-c:a",
                "aac",
                "-b:a",
                "384k",
                "-ar",
                "48000",
                "-ac",
                "2",
                "-movflags",
                "+faststart",
            ])
            .arg(&output);
        let rendered = command.output().unwrap();
        assert!(
            rendered.status.success(),
            "{}",
            String::from_utf8_lossy(&rendered.stderr)
        );

        let probe = StdCommand::new(&ffprobe)
            .args([
                "-v",
                "error",
                "-show_entries",
                "format=duration:stream=codec_type,codec_name,profile,width,height,pix_fmt,avg_frame_rate,sample_rate,channels,color_space,color_transfer,color_primaries",
                "-of",
                "json",
            ])
            .arg(&output)
            .output()
            .unwrap();
        assert!(probe.status.success());
        let metadata: serde_json::Value = serde_json::from_slice(&probe.stdout).unwrap();
        let streams = metadata["streams"].as_array().unwrap();
        let video = streams
            .iter()
            .find(|stream| stream["codec_type"] == "video")
            .unwrap();
        let audio = streams
            .iter()
            .find(|stream| stream["codec_type"] == "audio")
            .unwrap();
        assert_eq!(video["codec_name"], "h264");
        assert_eq!(video["profile"], "High");
        assert_eq!(video["width"], 1920);
        assert_eq!(video["height"], 1080);
        assert_eq!(video["pix_fmt"], "yuv420p");
        assert_eq!(video["avg_frame_rate"], OUTPUT_FPS);
        assert_eq!(video["color_space"], "bt709");
        assert_eq!(audio["codec_name"], "aac");
        assert_eq!(audio["sample_rate"], "48000");
        assert_eq!(audio["channels"], 2);
        let actual_duration = metadata["format"]["duration"]
            .as_str()
            .unwrap()
            .parse::<f64>()
            .unwrap();
        assert!((actual_duration - total_duration(&clips)).abs() < 0.1);
        assert_eq!(
            fs::read_to_string(&chapters_path).unwrap(),
            "0:00:00 SHISHAMO 1\r\n0:00:07 aiko 2\r\n"
        );

        let frames_directory = output_directory.join("frames");
        fs::create_dir_all(&frames_directory).unwrap();
        for (label, seconds) in [
            ("0000ms", "0.00"),
            ("0500ms", "0.50"),
            ("4500ms", "4.50"),
            ("5000ms", "5.00"),
            ("transition-7750ms", "7.75"),
            ("after-transition-8050ms", "8.05"),
        ] {
            let frame_path = frames_directory.join(format!("{label}.png"));
            let frame = StdCommand::new(&ffmpeg)
                .args([
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-y",
                    "-ss",
                    seconds,
                    "-i",
                ])
                .arg(&output)
                .args(["-frames:v", "1", "-update", "1"])
                .arg(&frame_path)
                .output()
                .unwrap();
            assert!(
                frame.status.success(),
                "{}",
                String::from_utf8_lossy(&frame.stderr)
            );
        }

        fs::remove_dir_all(&working).unwrap();
        println!("encoder={}", encoder.label);
        println!("video={}", output.display());
        println!("chapters={}", chapters_path.display());
        println!("project={}", project_path.display());
    }
}
