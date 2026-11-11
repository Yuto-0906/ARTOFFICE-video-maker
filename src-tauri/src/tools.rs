use std::{
    env,
    path::{Path, PathBuf},
    sync::OnceLock,
};

use crate::models::ToolStatus;

static RESOURCE_DIRECTORY: OnceLock<PathBuf> = OnceLock::new();

pub fn initialize_resource_directory(directory: PathBuf) {
    let _ = RESOURCE_DIRECTORY.set(directory);
}

fn roots_for_executable(exe: &Path) -> Vec<PathBuf> {
    let mut roots = Vec::new();
    if let Some(parent) = exe.parent() {
        roots.push(parent.to_path_buf());
        roots.push(parent.join("tools"));
        roots.push(parent.join("resources"));
        if parent.file_name().is_some_and(|name| name == "MacOS") {
            if let Some(contents) = parent
                .parent()
                .filter(|path| path.file_name().is_some_and(|name| name == "Contents"))
            {
                roots.push(contents.join("Resources"));
            }
        }
    }
    roots
}

fn candidate_roots() -> Vec<PathBuf> {
    let mut roots = env::current_exe()
        .map(|exe| roots_for_executable(&exe))
        .unwrap_or_default();
    if let Some(directory) = RESOURCE_DIRECTORY.get() {
        roots.push(directory.clone());
    }
    #[cfg(debug_assertions)]
    if env::var_os("AOV_BUNDLED_ONLY").is_none() {
        if let Some(project_root) = Path::new(env!("CARGO_MANIFEST_DIR")).parent() {
            roots.push(project_root.join("vendor-tools"));
        }
    }
    roots
}

fn executable_from_path(name: &str) -> Option<PathBuf> {
    let path_value = env::var_os("PATH")?;
    env::split_paths(&path_value)
        .map(|directory| directory.join(name))
        .find(|candidate| candidate.is_file())
}

fn find_with_env(variable: &str, names: &[&str]) -> Option<PathBuf> {
    let bundled_only = env::var_os("AOV_BUNDLED_ONLY").is_some();
    if let Some(value) = env::var_os(variable).filter(|_| !bundled_only) {
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
    if bundled_only {
        None
    } else {
        names.iter().find_map(|name| executable_from_path(name))
    }
}

pub fn ffmpeg() -> Option<PathBuf> {
    required_in_tests(
        find_with_env("AOV_FFMPEG_PATH", &[&executable_name("ffmpeg")]),
        "FFmpeg",
    )
}

pub fn ffprobe() -> Option<PathBuf> {
    required_in_tests(
        find_with_env("AOV_FFPROBE_PATH", &[&executable_name("ffprobe")]),
        "ffprobe",
    )
}

pub fn magick() -> Option<PathBuf> {
    find_with_env("AOV_MAGICK_PATH", &[&executable_name("magick")])
}

fn executable_name(name: &str) -> String {
    format!("{name}{}", env::consts::EXE_SUFFIX)
}

fn required_in_tests(path: Option<PathBuf>, _name: &str) -> Option<PathBuf> {
    #[cfg(test)]
    if env::var_os("AOV_REQUIRE_TOOLS").is_some() {
        assert!(path.is_some(), "Required runtime tool is missing: {_name}");
    }
    path
}

pub fn hide_console(command: &mut tokio::process::Command) {
    #[cfg(windows)]
    command.creation_flags(0x0800_0000);
    #[cfg(not(windows))]
    let _ = command;
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
        return required_in_tests(Some(path), "Noto Sans JP Black");
    }
    #[cfg(windows)]
    if env::var_os("AOV_BUNDLED_ONLY").is_none() {
        let windows_font = Path::new(r"C:\Windows\Fonts\NotoSansJP-VF.ttf");
        return required_in_tests(
            windows_font.is_file().then(|| windows_font.to_path_buf()),
            "Noto Sans JP Black",
        );
    }
    required_in_tests(None, "Noto Sans JP Black")
}

pub fn status() -> ToolStatus {
    ToolStatus {
        ffmpeg_path: ffmpeg().map(|path| path.to_string_lossy().into_owned()),
        ffprobe_path: ffprobe().map(|path| path.to_string_lossy().into_owned()),
        magick_path: magick().map(|path| path.to_string_lossy().into_owned()),
        font_path: font().map(|path| path.to_string_lossy().into_owned()),
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use std::path::Component;

    use super::{candidate_roots, roots_for_executable};
    use std::path::Path;

    #[test]
    fn relocated_mac_bundle_resolves_its_own_resources() {
        let root = Path::new("/tmp/移動先/ARTOFFICE.app/Contents");
        let roots = roots_for_executable(&root.join("MacOS/artoffice-video-maker"));
        assert!(roots.contains(&root.join("MacOS")));
        assert!(roots.contains(&root.join("Resources")));
        assert!(!roots
            .iter()
            .any(|path| path.to_string_lossy().contains("homebrew")));
    }

    #[test]
    fn bundled_tool_roots_do_not_contain_parent_components() {
        assert!(candidate_roots()
            .iter()
            .all(|path| !path.components().any(|part| part == Component::ParentDir)));
    }
}
