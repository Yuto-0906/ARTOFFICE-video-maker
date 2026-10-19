#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    let mut arguments = std::env::args_os().skip(1);
    if arguments
        .next()
        .is_some_and(|value| value == "--verify-runtime")
    {
        let result = arguments
            .next()
            .ok_or_else(|| anyhow::anyhow!("--verify-runtime requires an output directory"))
            .and_then(|directory| {
                artoffice_video_maker_lib::verify_runtime(std::path::Path::new(&directory))
            });
        if let Err(error) = result {
            eprintln!("{error:#}");
            std::process::exit(1);
        }
        return;
    }
    artoffice_video_maker_lib::run();
}
