use std::{
    sync::mpsc::{Receiver, RecvTimeoutError},
    time::Duration,
};

use windows::Win32::UI::Input::KeyboardAndMouse::{
    HOT_KEY_MODIFIERS, MOD_ALT, MOD_CONTROL, MOD_NOREPEAT, MOD_SHIFT, MOD_WIN, RegisterHotKey,
    UnregisterHotKey, VIRTUAL_KEY,
};
use windows::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, MSG, PM_REMOVE, PeekMessageW, TranslateMessage, WM_HOTKEY,
};

use flow_core::model::HotKey;

const HOTKEY_ID: i32 = 1;
const POLL_INTERVAL: Duration = Duration::from_millis(150);

#[derive(Debug)]
pub enum Command {
    Change(HotKey),
    Stop,
}

pub struct Callbacks<A, S> {
    pub activated: A,
    pub status: S,
}

/// Registers the preset's global shortcut and pumps a Win32 message loop until
/// the preset changes or the service stops.
pub fn run<A, S>(mut hot_key: HotKey, receiver: Receiver<Command>, callbacks: Callbacks<A, S>)
where
    A: Fn(()) + Send + Sync + 'static,
    S: Fn(String) + Send + Sync + 'static,
{
    loop {
        match register(&hot_key) {
            Ok(title) => (callbacks.status)(format!("Global shortcut: {title}")),
            Err(_) => (callbacks.status)(
                "Flow could not register its global shortcut. The key combination may already be in use."
                    .to_owned(),
            ),
        }
        match pump(&receiver, &callbacks) {
            LoopResult::Change(next) => {
                unregister();
                hot_key = next;
            }
            LoopResult::Stop => break,
        }
    }
    unregister();
}

enum LoopResult {
    Change(HotKey),
    Stop,
}

fn pump<A, S>(receiver: &Receiver<Command>, callbacks: &Callbacks<A, S>) -> LoopResult
where
    A: Fn(()) + Send + Sync + 'static,
    S: Fn(String) + Send + Sync + 'static,
{
    let mut message = MSG::default();
    loop {
        unsafe {
            while PeekMessageW(&mut message, None, 0, 0, PM_REMOVE).as_bool() {
                let _ = TranslateMessage(&message);
                DispatchMessageW(&message);
                if message.message == WM_HOTKEY && message.wParam.0 == HOTKEY_ID as usize {
                    (callbacks.activated)(());
                }
            }
        }
        match receiver.recv_timeout(POLL_INTERVAL) {
            Ok(Command::Change(next)) => return LoopResult::Change(next),
            Ok(Command::Stop) | Err(RecvTimeoutError::Disconnected) => return LoopResult::Stop,
            Err(RecvTimeoutError::Timeout) => {}
        }
    }
}

fn register(hot_key: &HotKey) -> Result<String, ()> {
    let (modifiers, key) = binding(hot_key).ok_or(())?;
    unsafe { RegisterHotKey(None, HOTKEY_ID, modifiers, key.0 as u32) }
        .is_ok()
        .then(|| hot_key.title("Win"))
        .ok_or(())
}

fn unregister() {
    unsafe {
        let _ = UnregisterHotKey(None, HOTKEY_ID);
    }
}

fn binding(hot_key: &HotKey) -> Option<(HOT_KEY_MODIFIERS, VIRTUAL_KEY)> {
    let mut modifiers = MOD_NOREPEAT.0;
    if hot_key.control {
        modifiers |= MOD_CONTROL.0;
    }
    if hot_key.alt {
        modifiers |= MOD_ALT.0;
    }
    if hot_key.shift {
        modifiers |= MOD_SHIFT.0;
    }
    if hot_key.super_key {
        modifiers |= MOD_WIN.0;
    }
    let key = match hot_key.key.as_str() {
        "Space" => 0x20,
        key if key.len() == 1 => key.as_bytes()[0].to_ascii_uppercase() as u16,
        key if key.starts_with('F') => {
            let number = key[1..].parse::<u16>().ok()?;
            if !(1..=12).contains(&number) {
                return None;
            }
            0x6F + number
        }
        _ => return None,
    };
    Some((HOT_KEY_MODIFIERS(modifiers), VIRTUAL_KEY(key)))
}
