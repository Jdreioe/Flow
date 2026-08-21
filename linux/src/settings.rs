use std::{fs, io, path::PathBuf};

use directories::ProjectDirs;
use flow_core::model::Settings;
use reqwest::Client;
use serde::Deserialize;

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

const GITHUB_REPO: &str = "jdreioe/Flow";
const GITHUB_API: &str = "https://api.github.com/repos/jdreioe/flow/releases/latest";

#[derive(Debug, Deserialize)]
struct Release {
    tag_name: String,
    name: String,
    published_at: String,
}

pub async fn check_for_update(current_version: &str) -> anyhow::Result<Option<Release>> {
    let client = Client::new();
    let resp = client.get(GITHUB_API).send().await?;
    if resp.status().is_success() {
        let release: Release = resp.json().await?;
        if release.tag_name != current_version {
            Ok(Some(release))
        } else {
            Ok(None)
        }
    } else {
        Ok(None)
    }
}

fn settings_path() -> Option<PathBuf> {
    ProjectDirs::from("io.github", "jdreioe", "Flow")
        .map(|dirs| dirs.config_dir().join("settings.json"))
}
