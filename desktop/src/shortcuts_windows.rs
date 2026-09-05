//! Windows global shortcut through RegisterHotKey.

use std::time::Duration;

use windows::Win32::UI::Input::KeyboardAndMouse::{
    HOT_KEY_MODIFIERS, MOD_ALT, MOD_CONTROL, MOD_NOREPEAT, MOD_WIN, RegisterHotKey,
    UnregisterHotKey, VIRTUAL_KEY,
};
use windows::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, MSG, PM_REMOVE, PeekMessageW, TranslateMessage, WM_HOTKEY,
};

use flow_core::model::HotKeyPreset;

use super::{Callbacks, Command, CommandReceiver};

const HOTKEY_ID: i32 = 1;
const POLL_INTERVAL: Duration = Duration::from_millis(150);

/// Registers the preset's global shortcut and pumps a Win32 message loop until
/// the preset changes or the service stops.
pub fn run(mut preset: HotKeyPreset, receiver: CommandReceiver, callbacks: Callbacks) {
    loop {
        match register(preset) {
            Ok(title) => (callbacks.status)(format!("Global shortcut: {title}")),
            Err(_) => (callbacks.status)(
                "Flow could not register its global shortcut. The key combination may already be in use."
                    .to_owned(),
            ),
        }
        match pump(&receiver, &callbacks) {
            LoopResult::Change(next) => {
                unregister();
                preset = next;
            }
            LoopResult::Stop => break,
        }
    }
    unregister();
}

enum LoopResult {
    Change(HotKeyPreset),
    Stop,
}

fn pump(receiver: &CommandReceiver, callbacks: &Callbacks) -> LoopResult {
    let mut message = MSG::default();
    loop {
        unsafe {
            while PeekMessageW(&mut message, None, 0, 0, PM_REMOVE).as_bool() {
                let _ = TranslateMessage(&message);
                DispatchMessageW(&message);
                if message.message == WM_HOTKEY && message.wParam.0 == HOTKEY_ID as usize {
                    (callbacks.activated)();
                }
            }
        }
        match receiver.try_recv() {
            Ok(Command::Change(next)) => return LoopResult::Change(next),
            Ok(Command::Stop) | Err(tokio::sync::mpsc::error::TryRecvError::Disconnected) => {
                return LoopResult::Stop;
            }
            Err(tokio::sync::mpsc::error::TryRecvError::Empty) => {
                std::thread::sleep(POLL_INTERVAL);
            }
        }
    }
}

fn register(preset: HotKeyPreset) -> Result<&'static str, ()> {
    let (modifiers, key) = binding(preset);
    unsafe { RegisterHotKey(None, HOTKEY_ID, modifiers, key.0 as u32) }
        .is_ok()
        .then(|| title(preset))
        .ok_or(())
}

fn unregister() {
    unsafe {
        let _ = UnregisterHotKey(None, HOTKEY_ID);
    }
}

fn binding(preset: HotKeyPreset) -> (HOT_KEY_MODIFIERS, VIRTUAL_KEY) {
    match preset {
        HotKeyPreset::AltSuperR => (
            HOT_KEY_MODIFIERS(MOD_ALT.0 | MOD_WIN.0 | MOD_NOREPEAT.0),
            VIRTUAL_KEY(0x52), // R
        ),
        HotKeyPreset::AltSuperSpace => (
            HOT_KEY_MODIFIERS(MOD_ALT.0 | MOD_WIN.0 | MOD_NOREPEAT.0),
            VIRTUAL_KEY(0x20), // Space
        ),
        HotKeyPreset::ControlAltR => (
            HOT_KEY_MODIFIERS(MOD_CONTROL.0 | MOD_ALT.0 | MOD_NOREPEAT.0),
            VIRTUAL_KEY(0x52), // R
        ),
    }
}

fn title(preset: HotKeyPreset) -> &'static str {
    match preset {
        HotKeyPreset::AltSuperR => "Alt+Win+R",
        HotKeyPreset::AltSuperSpace => "Alt+Win+Space",
        HotKeyPreset::ControlAltR => "Ctrl+Alt+R",
    }
}
