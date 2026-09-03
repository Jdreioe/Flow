use std::{fs, io, path::PathBuf};

use directories::ProjectDirs;
use flow_core::model::Settings;
use uuid::Uuid;

pub fn load() -> Settings {
    settings_path()
        .and_then(|path| fs::read(path).ok())
        .and_then(|bytes| migrate(&bytes))
        .unwrap_or_default()
}

fn migrate(bytes: &[u8]) -> Option<Settings> {
    let value: serde_json::Value = serde_json::from_slice(bytes).ok()?;
    let per_language =
        value.get("azureVoiceMode").and_then(|mode| mode.as_str()) == Some("perLanguage");
    let mut settings: Settings = serde_json::from_value(value).ok()?;
    if per_language
        && !settings.language_routes.iter().any(|route| {
            flow_core::model::language_base(&route.language_tag)
                == flow_core::model::language_base(&settings.default_language_tag)
        })
    {
        let mut route = settings.fallback_route();
        route.id = Uuid::new_v4();
        settings.language_routes.insert(0, route);
    }
    Some(settings)
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
