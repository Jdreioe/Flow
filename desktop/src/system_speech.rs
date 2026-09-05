//! System speech synthesis.
//!
//! Linux speaks through Speech Dispatcher, Windows through WinRT speech
//! synthesis. Both sides share the voice shape, the command channel, and the
//! word-range reporting used for popup highlighting.

use serde::Serialize;

use flow_core::language::Plan;

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SystemVoice {
    pub name: String,
    pub language_tag: String,
}

pub enum Command {
    Play {
        generation: u64,
        plan: Plan,
        /// UTF-16 offset of each sentence within the popup's playback text,
        /// matching the coordinate space of the cloud word timings.
        sentence_bases: Vec<u32>,
    },
    Pause,
    Resume,
    Stop,
    Shutdown,
}

pub struct Callbacks {
    pub voices_changed: Box<dyn Fn(Vec<SystemVoice>) + Send>,
    pub finished: Box<dyn Fn(u64) + Send>,
    pub failed: Box<dyn Fn((u64, String)) + Send>,
    pub word_range: Box<dyn Fn((u64, u32, u32)) + Send>,
}

#[cfg(target_os = "linux")]
#[path = "system_speech_linux.rs"]
mod platform;

#[cfg(target_os = "windows")]
#[path = "system_speech_windows.rs"]
mod platform;

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
compile_error!("Flow desktop supports Linux and Windows only");

pub use platform::start;
