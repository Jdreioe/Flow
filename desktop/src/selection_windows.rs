use std::process;

use thiserror::Error;
use windows::Win32::{
    System::Com::{
        CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, CoCreateInstance, CoInitializeEx,
        CoUninitialize,
    },
    UI::Accessibility::{
        CUIAutomation, IUIAutomation, IUIAutomationTextPattern, UIA_TextPatternId,
    },
};

const MAXIMUM_ANCESTORS: usize = 8;

#[derive(Debug, Error)]
pub enum SelectionError {
    #[error("Select some text, then use the Flow shortcut.")]
    NoSelectedText,
    #[error("This application does not expose its selected text through Windows UI Automation.")]
    Unavailable,
}

struct ComScope;

impl ComScope {
    fn new() -> Self {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        };
        ComScope
    }
}

impl Drop for ComScope {
    fn drop(&mut self) {
        unsafe { CoUninitialize() };
    }
}

/// Reads selected text from the focused application through UI Automation.
///
/// Flow never asks for an element's complete text value: only explicit
/// TextPattern selection ranges are resolved. The focused element is checked
/// first, then its ancestors, because editors often expose the text pattern on
/// a parent document element rather than the caret host.
pub fn read_focused_selection() -> Result<String, SelectionError> {
    let _com = ComScope::new();
    let automation: IUIAutomation =
        unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER) }
            .map_err(|_| SelectionError::Unavailable)?;
    let focused =
        unsafe { automation.GetFocusedElement() }.map_err(|_| SelectionError::Unavailable)?;

    let owner = unsafe { focused.CurrentProcessId() }.map_err(|_| SelectionError::Unavailable)?;
    if owner >= 0 && owner as u32 == process::id() {
        return Err(SelectionError::Unavailable);
    }

    let walker =
        unsafe { automation.ControlViewWalker() }.map_err(|_| SelectionError::Unavailable)?;
    let mut element = Some(focused);
    let mut found_text_pattern = false;
    for _ in 0..=MAXIMUM_ANCESTORS {
        let Some(current) = element else { break };
        if let Ok(pattern) =
            unsafe { current.GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId) }
        {
            found_text_pattern = true;
            if let Some(text) = selected_text(&pattern) {
                debug_selection("UI Automation", &text);
                return Ok(text);
            }
        }
        element = unsafe { walker.GetParentElement(&current) }.ok();
    }

    Err(if found_text_pattern {
        SelectionError::NoSelectedText
    } else {
        SelectionError::Unavailable
    })
}

fn selected_text(pattern: &IUIAutomationTextPattern) -> Option<String> {
    let array = unsafe { pattern.GetSelection() }.ok()?;
    let length = unsafe { array.Length() }.ok()?;
    for index in 0..length {
        let Ok(range) = (unsafe { array.GetElement(index) }) else {
            continue;
        };
        let Ok(text) = (unsafe { range.GetText(-1) }).map(|value| value.to_string()) else {
            continue;
        };
        if !text.trim().is_empty() {
            return Some(truncate(&text));
        }
    }
    None
}

fn truncate(text: &str) -> String {
    match flow_core::model::MAXIMUM_SELECTION_CHARACTERS
        .checked_sub(1)
        .and_then(|limit| text.char_indices().nth(limit).map(|(index, _)| index))
    {
        Some(index) => text[..index].to_owned(),
        None => text.to_owned(),
    }
}

/// Windows needs no accessibility pre-enable; kept for interface parity.
pub fn enable_accessibility() {}

pub fn debug_enabled() -> bool {
    cfg!(debug_assertions)
        && std::env::var("FLOW_DEBUG_SELECTION").is_ok_and(|value| {
            matches!(
                value.to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            )
        })
}

#[cfg(debug_assertions)]
fn debug_selection(source: &str, text: &str) {
    if debug_enabled() {
        eprintln!("[Flow selection] source={source}; text={text:?}");
    }
}

#[cfg(not(debug_assertions))]
fn debug_selection(_: &str, _: &str) {}
