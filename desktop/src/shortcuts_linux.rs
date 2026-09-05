//! Linux global shortcut through the XDG global-shortcuts portal.

use ashpd::{
    WindowIdentifier,
    desktop::{
        CreateSessionOptions,
        global_shortcuts::{BindShortcutsOptions, GlobalShortcuts, NewShortcut},
    },
};
use futures_util::StreamExt;

use flow_core::model::HotKeyPreset;

use super::{Callbacks, Command, CommandReceiver};

/// Registers the preset's global shortcut and blocks until the preset changes
/// or the service stops. Runs its own runtime so callers stay synchronous.
pub fn run(preset: HotKeyPreset, commands: CommandReceiver, callbacks: Callbacks) {
    let Ok(runtime) = tokio::runtime::Runtime::new() else {
        (callbacks.status)(
            "Global shortcuts are unavailable on this desktop. Use Read selected text from Flow's tray menu."
                .into(),
        );
        return;
    };
    runtime.block_on(run_async(preset, commands, &callbacks));
    let _ = preset;
}

async fn run_async(
    mut preset: HotKeyPreset,
    mut commands: CommandReceiver,
    callbacks: &Callbacks,
) {
    loop {
        match run_session(preset, &mut commands, callbacks).await {
            SessionResult::Change(next) => preset = next,
            SessionResult::Stop => break,
            SessionResult::Failed(message) => {
                (callbacks.status)(message);
                match commands.recv().await {
                    Some(Command::Change(next)) => preset = next,
                    Some(Command::Stop) | None => break,
                }
            }
        }
    }
}

enum SessionResult {
    Change(HotKeyPreset),
    Stop,
    Failed(String),
}

async fn run_session(
    preset: HotKeyPreset,
    commands: &mut CommandReceiver,
    callbacks: &Callbacks,
) -> SessionResult {
    let portal = match GlobalShortcuts::new().await {
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
                "Flow could not create a global shortcut session.".into(),
            );
        }
    };
    let shortcut = NewShortcut::new("read-selection", "Read selected text")
        .preferred_trigger(Some(preset.preferred_trigger()));
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
                    Some(event) if event.shortcut_id() == "read-selection" => (callbacks.activated)(),
                    Some(_) => {}
                    None => return SessionResult::Failed("The global shortcut session ended unexpectedly.".into()),
                }
            }
        }
    }
}
