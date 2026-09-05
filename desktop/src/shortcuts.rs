//! Global shortcut registration.
//!
//! Linux goes through the XDG global-shortcuts portal, Windows through
//! RegisterHotKey. Both sides share the command channel and the callback
//! shape so the controller treats them identically.

use flow_core::model::HotKeyPreset;
use tokio::sync::mpsc::UnboundedReceiver;

#[derive(Debug)]
pub enum Command {
    Change(HotKeyPreset),
    Stop,
}

pub type CommandReceiver = UnboundedReceiver<Command>;

pub struct Callbacks {
    pub activated: Box<dyn Fn() + Send + Sync>,
    pub status: Box<dyn Fn(String) + Send + Sync>,
}

#[cfg(target_os = "linux")]
#[path = "shortcuts_linux.rs"]
mod platform;

#[cfg(target_os = "windows")]
#[path = "shortcuts_windows.rs"]
mod platform;

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
compile_error!("Flow desktop supports Linux and Windows only");

pub use platform::run;
