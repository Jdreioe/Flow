//! Self-updating for Flow distributed through Velopack. Checking downloads
//! the pending release; restarting applies it.

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

const UPDATE_FEED: &str =
    "https://github.com/jdreioe/flow/releases/latest/download/releases.win.json";

fn update_manager() -> Result<velopack::UpdateManager, String> {
    let source = velopack::sources::HttpSource::new(UPDATE_FEED);
    velopack::UpdateManager::new(source, None, None).map_err(|_| {
        "Flow can only check for updates when running from an installed build.".to_owned()
    })
}

pub fn check() -> Result<Outcome, String> {
    let manager = update_manager()?;
    match manager
        .check_for_updates()
        .map_err(|_| "Flow could not check for updates.".to_owned())?
    {
        velopack::UpdateCheck::RemoteIsEmpty | velopack::UpdateCheck::NoUpdateAvailable => {
            Ok(Outcome::UpToDate)
        }
        velopack::UpdateCheck::UpdateAvailable(update) => {
            let version = update.TargetFullRelease.Version.clone();
            manager
                .download_updates(&update, None)
                .map_err(|_| format!("Flow found version {version} but could not download it."))?;
            Ok(Outcome::Staged(version))
        }
    }
}

/// Applies the staged update and restarts. Never returns on success.
pub fn apply_staged_and_restart() -> Result<(), String> {
    let manager = update_manager()?;
    let pending = manager
        .get_update_pending_restart()
        .ok_or_else(|| "No downloaded Flow update is pending. Check for Updates first.".to_owned())?;
    manager.apply_updates_and_restart(pending).map_err(|_| {
        "Flow could not apply its update. Download it from github.com/jdreioe/flow/releases."
            .to_owned()
    })
}
