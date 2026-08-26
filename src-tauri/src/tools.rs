use std::{
    env,
    path::{Path, PathBuf},
};

use crate::models::ToolStatus;

fn candidate_roots() -> Vec<PathBuf> {
    let mut roots = Vec::new();
    if let Ok(exe) = env::current_exe() {
        if let Some(parent) = exe.parent() {
            roots.push(parent.to_path_buf());
            roots.push(parent.join("tools"));
            roots.push(parent.join("resources"));
        }
    }
    roots.push(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("vendor-tools"),
    );
    roots
}

fn executable_from_path(name: &str) -> Option<PathBuf> {
    let path_value = env::var_os("PATH")?;
    env::split_paths(&path_value)
        .map(|directory| directory.join(name))
        .find(|candidate| candidate.is_file())
}

fn find_with_env(variable: &str, names: &[&str]) -> Option<PathBuf> {
    if let Some(value) = env::var_os(variable) {
        let path = PathBuf::from(value);
        if path.is_file() {
            return Some(path);
        }
    }
    for root in candidate_roots() {
        for name in names {
            let direct = root.join(name);
            if direct.is_file() {
                return Some(direct);
            }
            let nested = root.join("ffmpeg").join("bin").join(name);
            if nested.is_file() {
                return Some(nested);
            }
            let imagemagick = root.join("imagemagick").join(name);
            if imagemagick.is_file() {
                return Some(imagemagick);
            }
        }
    }
    names.iter().find_map(|name| executable_from_path(name))
}

pub fn ffmpeg() -> Option<PathBuf> {
    find_with_env("AOV_FFMPEG_PATH", &["ffmpeg.exe", "ffmpeg"])
}

pub fn ffprobe() -> Option<PathBuf> {
    find_with_env("AOV_FFPROBE_PATH", &["ffprobe.exe", "ffprobe"])
}

pub fn magick() -> Option<PathBuf> {
    find_with_env("AOV_MAGICK_PATH", &["magick.exe", "magick"])
}

pub fn font() -> Option<PathBuf> {
    if let Some(path) = find_with_env(
        "AOV_FONT_PATH",
        &[
            "resources/fonts/NotoSansJP-Black.ttf",
            "fonts/NotoSansJP-Black.ttf",
            "NotoSansJP-Black.ttf",
            "NotoSansCJKjp-Black.otf",
        ],
    ) {
        return Some(path);
    }
    let windows_font = Path::new(r"C:\Windows\Fonts\NotoSansJP-VF.ttf");
    windows_font.is_file().then(|| windows_font.to_path_buf())
}

pub fn status() -> ToolStatus {
    ToolStatus {
        ffmpeg_path: ffmpeg().map(|path| path.to_string_lossy().into_owned()),
        ffprobe_path: ffprobe().map(|path| path.to_string_lossy().into_owned()),
        magick_path: magick().map(|path| path.to_string_lossy().into_owned()),
        font_path: font().map(|path| path.to_string_lossy().into_owned()),
    }
}
