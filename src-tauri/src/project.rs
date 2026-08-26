use std::{fs, path::Path};

use anyhow::{Context, Result};

use crate::models::ProjectV1;

pub fn read(path: &str) -> Result<ProjectV1> {
    let data =
        fs::read(path).with_context(|| format!("プロジェクトを読み取れませんでした: {path}"))?;
    let project: ProjectV1 =
        serde_json::from_slice(&data).context("プロジェクトJSONが壊れています。")?;
    project.validate()?;
    Ok(project)
}

pub fn write(path: &str, project: &ProjectV1) -> Result<()> {
    project.validate()?;
    let destination = Path::new(path);
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent).context("保存先フォルダーを作成できませんでした。")?;
    }
    let data =
        serde_json::to_vec_pretty(project).context("プロジェクトをJSONへ変換できませんでした。")?;
    fs::write(destination, data).context("プロジェクトを保存できませんでした。")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{read, write};
    use crate::models::{ProjectV1, Resolution};

    #[test]
    fn round_trips_project() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("sample.aovproj");
        let project = ProjectV1 {
            schema_version: 1,
            app_version: "0.1.0".to_string(),
            event_name: "8月ライブ".to_string(),
            clips: Vec::new(),
            output_resolution: Resolution::P1080,
            transition_ms: 500,
            thumbnail: None,
        };
        write(path.to_str().unwrap(), &project).unwrap();
        let loaded = read(path.to_str().unwrap()).unwrap();
        assert_eq!(loaded.event_name, "8月ライブ");
    }
}
