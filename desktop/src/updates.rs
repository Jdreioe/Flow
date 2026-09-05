//! Self-updating: AppImage swap on Linux, Velopack on Windows.

#[cfg(target_os = "linux")]
#[path = "updates_linux.rs"]
mod platform;

#[cfg(target_os = "windows")]
#[path = "updates_windows.rs"]
mod platform;

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
compile_error!("Flow desktop supports Linux and Windows only");

pub use platform::{Outcome, VERSION, apply_staged_and_restart, check};
