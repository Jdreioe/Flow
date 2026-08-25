//! Self-updating for Flow distributed as an AppImage. The GitHub "latest"
//! release must carry an x86_64 AppImage asset; checking stages it next to
//! the running AppImage so the restart swap stays on one filesystem.

use std::{fs, os::unix::fs::PermissionsExt, path::PathBuf};

use serde::Deserialize;

const GITHUB_API_LATEST: &str = "https://api.github.com/repos/jdreioe/Flow/releases/latest";

/// Release builds embed their marketing version here because the Cargo
/// workspace version does not track release tags.
pub const VERSION: &str = match option_env!("FLOW_VERSION") {
    Some(version) => version,
    None => env!("CARGO_PKG_VERSION"),
};

pub enum Outcome {
    UpToDate,
    Staged(String),
}

#[derive(Deserialize)]
struct Release {
    tag_name: String,
    #[serde(default)]
    assets: Vec<Asset>,
}

#[derive(Deserialize)]
struct Asset {
    name: String,
    browser_download_url: String,
}

fn not_appimage_error() -> String {
    "Flow can only self-update when installed as an AppImage. Download the latest release from github.com/jdreioe/flow/releases."
        .to_owned()
}

/// Path of the running AppImage, or None for unpackaged development builds.
fn appimage_path() -> Option<PathBuf> {
    let path = PathBuf::from(std::env::var_os("APPIMAGE")?);
    path.is_file().then_some(path)
}

fn staged_path(appimage: &std::path::Path) -> PathBuf {
    let mut name = appimage
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "flow.AppImage".to_owned());
    name.push_str(".download");
    appimage.with_file_name(name)
}

fn fetch_latest_release() -> Result<Release, String> {
    reqwest::blocking::Client::new()
        .get(GITHUB_API_LATEST)
        .header(
            reqwest::header::USER_AGENT,
            concat!("flow-linux/", env!("CARGO_PKG_VERSION")),
        )
        .send()
        .map_err(|_| "Flow could not reach github.com to check for updates.".to_owned())?
        .error_for_status()
        .map_err(|_| "GitHub reported an error while checking for updates.".to_owned())?
        .json()
        .map_err(|_| "Flow could not read the latest release information.".to_owned())
}

fn numeric_version(tag: &str) -> Vec<u64> {
    tag.trim_start_matches('v')
        .split(|c: char| !c.is_ascii_digit())
        .filter(|part| !part.is_empty())
        .filter_map(|part| part.parse::<u64>().ok())
        .collect()
}

fn is_newer(candidate: &[u64], current: &[u64]) -> bool {
    for index in 0..candidate.len().max(current.len()) {
        match (
            candidate.get(index).copied().unwrap_or(0),
            current.get(index).copied().unwrap_or(0),
        ) {
            (left, right) if left != right => return left > right,
            _ => continue,
        }
    }
    false
}

fn appimage_asset(release: &Release) -> Result<&Asset, String> {
    const MACHINE: &str = if cfg!(target_arch = "aarch64") {
        "aarch64"
    } else {
        "x86_64"
    };
    release
        .assets
        .iter()
        .find(|asset| asset.name.ends_with(".AppImage") && asset.name.contains(MACHINE))
        .or_else(|| {
            release
                .assets
                .iter()
                .find(|asset| asset.name.ends_with(".AppImage"))
        })
        .ok_or_else(|| {
            format!(
                "Flow {} was published without a Linux AppImage.",
                release.tag_name
            )
        })
}

fn stage_update(
    release_tag: &str,
    asset_url: &str,
    appimage: &std::path::Path,
) -> Result<(), String> {
    let response = reqwest::blocking::Client::new()
        .get(asset_url)
        .header(
            reqwest::header::USER_AGENT,
            concat!("flow-linux/", env!("CARGO_PKG_VERSION")),
        )
        .send()
        .map_err(|_| format!("Flow found version {release_tag} but could not download it."))?
        .error_for_status()
        .map_err(|_| format!("Flow found version {release_tag} but could not download it."))?;
    let bytes = response
        .bytes()
        .map_err(|_| format!("Flow found version {release_tag} but could not download it."))?;
    let staged = staged_path(appimage);
    fs::write(&staged, &bytes)
        .map_err(|_| "Flow could not save the update next to the running AppImage. Move Flow somewhere writable, then try again.".to_owned())?;
    fs::set_permissions(&staged, fs::Permissions::from_mode(0o755))
        .map_err(|_| "Flow downloaded the update but could not make it executable.".to_owned())?;
    Ok(())
}

pub fn check() -> Result<Outcome, String> {
    let Some(appimage) = appimage_path() else {
        return Err(not_appimage_error());
    };
    let release = fetch_latest_release()?;
    if !is_newer(
        &numeric_version(&release.tag_name),
        &numeric_version(VERSION),
    ) {
        return Ok(Outcome::UpToDate);
    }
    let asset = appimage_asset(&release)?;
    let version = release.tag_name.trim_start_matches('v').to_owned();
    stage_update(&release.tag_name, &asset.browser_download_url, &appimage)?;
    Ok(Outcome::Staged(version))
}

/// Swaps the staged update into place, starts it, and exits this process.
/// Never returns on success.
pub fn apply_staged_and_restart() -> Result<(), String> {
    let Some(appimage) = appimage_path() else {
        return Err(not_appimage_error());
    };
    let staged = staged_path(&appimage);
    if !staged.is_file() {
        return Err("No downloaded Flow update is pending. Check for Updates first.".to_owned());
    }
    let backup = appimage.with_file_name(format!(
        "{}.old",
        appimage
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| "flow.AppImage".to_owned())
    ));
    let restore_backup = |from: &std::path::Path, to: &std::path::Path| {
        let _ = fs::rename(from, to);
    };
    fs::rename(&appimage, &backup).map_err(|_| {
        "Flow could not replace the running AppImage. Move Flow somewhere writable, then try again."
            .to_owned()
    })?;
    if let Err(error) = fs::rename(&staged, &appimage) {
        restore_backup(&backup, &appimage);
        return Err(format!("Flow could not install its update: {error}"));
    }
    if std::process::Command::new(&appimage).spawn().is_err() {
        restore_backup(&backup, &appimage);
        return Err("Flow updated itself but could not restart. Start Flow again.".to_owned());
    }
    std::process::exit(0);
}
