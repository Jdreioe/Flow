use std::path::{Path, PathBuf};

use ashpd::{
    WindowIdentifier,
    desktop::{
        CreateSessionOptions,
        global_shortcuts::{BindShortcutsOptions, GlobalShortcuts, NewShortcut},
    },
};
use futures_util::StreamExt;
use tokio::sync::mpsc;

use flow_core::model::HotKey;

#[derive(Debug)]
pub enum Command {
    Change(HotKey),
    Stop,
}

pub struct Callbacks<A, S> {
    pub activated: A,
    pub status: S,
}

pub async fn run<A, S>(
    mut hot_key: HotKey,
    mut commands: mpsc::UnboundedReceiver<Command>,
    callbacks: Callbacks<A, S>,
) where
    A: Fn(()) + Send + Sync + 'static,
    S: Fn(String) + Send + Sync + 'static,
{
    loop {
        match run_session(&hot_key, &mut commands, &callbacks).await {
            SessionResult::Change(next) => hot_key = next,
            SessionResult::Stop => break,
            SessionResult::Failed(message) => {
                (callbacks.status)(message);
                match commands.recv().await {
                    Some(Command::Change(next)) => hot_key = next,
                    Some(Command::Stop) | None => break,
                }
            }
        }
    }
}

enum SessionResult {
    Change(HotKey),
    Stop,
    Failed(String),
}

async fn run_session<A, S>(
    hot_key: &HotKey,
    commands: &mut mpsc::UnboundedReceiver<Command>,
    callbacks: &Callbacks<A, S>,
) -> SessionResult
where
    A: Fn(()) + Send + Sync + 'static,
    S: Fn(String) + Send + Sync + 'static,
{
    let connection = match zbus::Connection::session().await {
        Ok(connection) => connection,
        Err(_) => {
            return SessionResult::Failed(
                "Global shortcuts are unavailable on this desktop. Use Read selected text from Flow's tray menu."
                    .into(),
            );
        }
    };
    // Processes started outside a systemd app scope (for example from a
    // terminal) have no application ID, and the portal rejects their session
    // requests. Registering first gives these launches the same identity as
    // a menu launch, as long as Flow's desktop file is installed.
    register_app_id(&connection).await;
    let portal = match GlobalShortcuts::with_connection(connection).await {
        Ok(portal) => portal,
        Err(_) => {
            return SessionResult::Failed(
                "Global shortcuts are unavailable on this desktop. Use Read selected text from Flow's tray menu."
                    .into(),
            );
        }
    };
    let session = match portal.create_session(CreateSessionOptions::default()).await {
        Ok(session) => session,
        Err(_) => {
            return SessionResult::Failed(
                "Flow could not create a global shortcut session. Install Flow's app launcher entry and start Flow from your app menu, then try again."
                    .into(),
            );
        }
    };
    let trigger = hot_key.preferred_trigger();
    let shortcut = NewShortcut::new("read-selection", "Read selected text")
        .preferred_trigger(Some(trigger.as_str()));
    let request = match portal
        .bind_shortcuts(
            &session,
            &[shortcut],
            Option::<&WindowIdentifier>::None,
            BindShortcutsOptions::default(),
        )
        .await
    {
        Ok(request) => request,
        Err(_) => {
            return SessionResult::Failed("Flow could not request its global shortcut.".into());
        }
    };
    let response = match request.response() {
        Ok(response) => response,
        Err(_) => {
            return SessionResult::Failed("The global shortcut request was cancelled.".into());
        }
    };
    let Some(bound) = response.shortcuts().first() else {
        return SessionResult::Failed("No global shortcut was assigned to Flow.".into());
    };
    (callbacks.status)(format!("Global shortcut: {}", bound.trigger_description()));

    let mut activations = match portal.receive_activated().await {
        Ok(activations) => Box::pin(activations),
        Err(_) => {
            return SessionResult::Failed("Flow could not listen for its global shortcut.".into());
        }
    };
    loop {
        tokio::select! {
            command = commands.recv() => {
                return match command {
                    Some(Command::Change(next)) => SessionResult::Change(next),
                    Some(Command::Stop) | None => SessionResult::Stop,
                };
            }
            activation = activations.next() => {
                match activation {
                    Some(event) if event.shortcut_id() == "read-selection" => (callbacks.activated)(()),
                    Some(_) => {}
                    None => return SessionResult::Failed("The global shortcut session ended unexpectedly.".into()),
                }
            }
        }
    }
}

/// Basename of the desktop file shipped in `linux/`, used when no installed
/// launcher entry matches this executable.
const FALLBACK_APP_ID: &str = "io.github.jdreioe.flow";

/// Associates this process's portal connection with Flow's application ID.
/// Best effort: older portals lack the Registry interface, and registration
/// fails when no matching desktop file is installed. Either way the caller
/// falls through to the normal session request.
async fn register_app_id(connection: &zbus::Connection) {
    let Some(app_id) = resolve_app_id() else {
        return;
    };
    let proxy = match zbus::Proxy::new(
        connection,
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.host.portal.Registry",
    )
    .await
    {
        Ok(proxy) => proxy,
        Err(_) => return,
    };
    let options: std::collections::HashMap<String, zbus::zvariant::OwnedValue> =
        Default::default();
    let _: Result<(), zbus::Error> = proxy.call("Register", &(app_id.as_str(), &options)).await;
}

fn resolve_app_id() -> Option<String> {
    let exe = std::env::current_exe().ok()?;
    let id = app_id_for_executable(&exe, &data_dirs());
    Some(id.unwrap_or_else(|| FALLBACK_APP_ID.to_owned()))
}

/// Finds the installed desktop file whose `Exec` line launches `exe` and
/// returns its basename (the application ID the portal expects).
fn app_id_for_executable(exe: &Path, data_dirs: &[PathBuf]) -> Option<String> {
    let mut targets = Vec::new();
    if let Ok(canonical) = std::fs::canonicalize(exe) {
        targets.push(canonical);
    }
    // Inside an AppImage the executable is the mounted runtime copy, while
    // launcher entries point at the AppImage file itself.
    if let Some(appimage) = std::env::var_os("APPIMAGE")
        && let Ok(canonical) = std::fs::canonicalize(PathBuf::from(appimage))
    {
        targets.push(canonical);
    }
    if targets.is_empty() {
        return None;
    }
    for dir in data_dirs {
        let entries = std::fs::read_dir(dir.join("applications")).ok()?;
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().is_none_or(|ext| ext != "desktop") {
                continue;
            }
            if desktop_exec_target(&path).is_some_and(|target| targets.contains(&target))
                && let Some(id) = path.file_stem().and_then(|stem| stem.to_str())
            {
                return Some(id.to_owned());
            }
        }
    }
    None
}

/// Resolves the program a desktop file's `Exec` line starts, skipping the
/// field codes and an `env` prefix with its assignments.
fn desktop_exec_target(desktop: &Path) -> Option<PathBuf> {
    let content = std::fs::read_to_string(desktop).ok()?;
    let exec = content
        .lines()
        .map(str::trim)
        .find_map(|line| line.strip_prefix("Exec="))?;
    let mut tokens = exec.split_whitespace();
    let mut program = tokens.next()?;
    if program == "env" {
        program = tokens.find(|token| !token.contains('='))?;
    }
    let program = program.trim_matches('"');
    if program.contains('/') {
        std::fs::canonicalize(program).ok()
    } else {
        std::env::var_os("PATH").and_then(|paths| {
            std::env::split_paths(&paths)
                .find_map(|dir| std::fs::canonicalize(dir.join(program)).ok())
        })
    }
}

fn data_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    match std::env::var_os("XDG_DATA_HOME") {
        Some(home) => dirs.push(PathBuf::from(home)),
        None => {
            if let Some(base) = directories::BaseDirs::new() {
                dirs.push(base.data_dir().to_path_buf());
            }
        }
    }
    match std::env::var_os("XDG_DATA_DIRS") {
        Some(system) => dirs.extend(std::env::split_paths(&system)),
        None => {
            dirs.push(PathBuf::from("/usr/local/share"));
            dirs.push(PathBuf::from("/usr/share"));
        }
    }
    dirs
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn write_desktop(dir: &Path, name: &str, exec: &str) -> PathBuf {
        let apps = dir.join("applications");
        std::fs::create_dir_all(&apps).expect("apps dir");
        let path = apps.join(name);
        let mut file = std::fs::File::create(&path).expect("desktop file");
        writeln!(file, "[Desktop Entry]").unwrap();
        writeln!(file, "Type=Application").unwrap();
        writeln!(file, "Exec={exec}").unwrap();
        path
    }

    #[test]
    fn finds_desktop_entry_matching_the_executable() {
        let home = tempfile::tempdir().expect("temp dir");
        let target = home.path().join("flow-test.AppImage");
        std::fs::write(&target, b"fake").expect("fake appimage");
        write_desktop(
            home.path(),
            "flow.desktop",
            &format!("env FOO=1 {} %f", target.display()),
        );
        let found = app_id_for_executable(&target, &[home.path().to_path_buf()]);
        assert_eq!(found.as_deref(), Some("flow"));
    }

    #[test]
    fn ignores_unrelated_desktop_entries() {
        let home = tempfile::tempdir().expect("temp dir");
        let target = home.path().join("flow-test.AppImage");
        std::fs::write(&target, b"fake").expect("fake appimage");
        write_desktop(home.path(), "other.desktop", "/usr/bin/other --flag");
        let found = app_id_for_executable(&target, &[home.path().to_path_buf()]);
        assert_eq!(found, None);
    }
}
