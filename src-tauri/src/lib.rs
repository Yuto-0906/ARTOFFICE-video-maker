mod media;
mod models;
mod project;
mod render;
mod thumbnail;
mod tools;

use models::{
    OutputPaths, PreparedThumbnail, ProbeResult, ProjectV1, RenderRequest, RenderStarted,
    ToolStatus,
};
use render::RenderState;
use tauri::{AppHandle, Manager, State};

fn command_error(error: anyhow::Error) -> String {
    format!("{error:#}")
}

#[tauri::command]
fn tool_status() -> ToolStatus {
    tools::status()
}

#[tauri::command]
fn list_mp4_files(folder: String) -> Result<Vec<String>, String> {
    media::mp4_files(&folder).map_err(command_error)
}

#[tauri::command]
async fn probe_media(paths: Vec<String>) -> Vec<ProbeResult> {
    media::probe_paths(paths).await
}

#[tauri::command]
fn read_project(path: String) -> Result<ProjectV1, String> {
    project::read(&path).map_err(command_error)
}

#[tauri::command]
fn write_project(path: String, project: ProjectV1) -> Result<(), String> {
    project::write(&path, &project).map_err(command_error)
}

#[tauri::command]
async fn prepare_thumbnail(source_path: String) -> Result<PreparedThumbnail, String> {
    thumbnail::prepare(&source_path)
        .await
        .map_err(command_error)
}

#[tauri::command]
fn output_paths(request: RenderRequest) -> Result<OutputPaths, String> {
    render::output_paths_for(&request).map_err(command_error)
}

#[tauri::command]
async fn start_render(
    app: AppHandle,
    state: State<'_, RenderState>,
    request: RenderRequest,
) -> Result<RenderStarted, String> {
    render::start(app, state.inner().clone(), request)
        .await
        .map_err(command_error)
}

#[tauri::command]
async fn cancel_render(state: State<'_, RenderState>, job_id: String) -> Result<bool, String> {
    Ok(state.cancel(&job_id).await)
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_log::Builder::new().build())
        .manage(RenderState::default())
        .setup(|app| {
            thumbnail::cleanup_cache();
            render::cleanup_cache();
            let window = app
                .get_webview_window("main")
                .expect("main window must exist");
            window.set_title("ARTOFFICE広報動画作成ソフト")?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            tool_status,
            list_mp4_files,
            probe_media,
            read_project,
            write_project,
            prepare_thumbnail,
            output_paths,
            start_render,
            cancel_render,
        ])
        .run(tauri::generate_context!())
        .expect("ARTOFFICE広報動画作成ソフトを起動できませんでした");
}
