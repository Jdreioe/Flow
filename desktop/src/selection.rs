//! Selected-text capture from the focused application.
//!
//! The implementation stays native per OS (AT-SPI on Linux, UI Automation on
//! Windows) behind one synchronous interface: Flow never reads an element's
//! complete text value, only explicit selection ranges.

#[cfg(target_os = "linux")]
#[path = "selection_linux.rs"]
mod platform;

#[cfg(target_os = "windows")]
#[path = "selection_windows.rs"]
mod platform;

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
compile_error!("Flow desktop supports Linux and Windows only");

pub use platform::{debug_enabled, enable_accessibility, read_focused_selection};
