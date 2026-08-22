use std::{fs, io, path::PathBuf};

use directories::ProjectDirs;
use flow_core::model::Settings;

pub fn load() -> Settings {
    settings_path()
        .and_then(|path| fs::read(path).ok())
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

pub fn save(settings: &Settings) -> io::Result<()> {
    let Some(path) = settings_path() else {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "no user configuration directory is available",
        ));
    };
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let data = serde_json::to_vec_pretty(settings).map_err(io::Error::other)?;
    fs::write(path, data)
}

fn settings_path() -> Option<PathBuf> {
    ProjectDirs::from("io.github", "jdreioe", "Flow")
        .map(|dirs| dirs.config_dir().join("settings.json"))
}
