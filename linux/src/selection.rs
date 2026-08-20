use std::{io::Read, time::Duration};

use atspi_common::{Interface, MatchType, ObjectMatchRule, SortOrder, State};
use atspi_connection::set_session_accessibility;
use atspi_proxies::{accessible::ObjectRefExt, proxy_ext::ProxyExt};
use thiserror::Error;
use wl_clipboard_rs::paste::{ClipboardType, MimeType, Seat, get_contents};

use flow_core::model::MAXIMUM_SELECTION_CHARACTERS;

const MAXIMUM_VISITED_ELEMENTS_PER_WINDOW: usize = 2_000;

struct SearchRoot {
    application_name: String,
    object: atspi_common::ObjectRefOwned,
}

#[derive(Debug, Error)]
pub enum SelectionError {
    #[error("Select some text, then use the Flow shortcut.")]
    NoSelectedText,
    #[error("This application does not expose its selected text through Linux accessibility.")]
    Unavailable,
}

/// Reads selected text from the desktop's AT-SPI trees.
///
/// Flow never asks for an object's complete text value: only explicit AT-SPI
/// selection ranges are resolved. Active windows are checked first. Other
/// windows are then checked because opening a tray menu can remove the active
/// state from the application whose selection the user wants to read.
pub async fn read_focused_selection() -> Result<String, SelectionError> {
    if set_session_accessibility(true).await.is_err() {
        return primary_selection_or_unavailable("unknown");
    }
    let Ok(atspi) = atspi_connection::AccessibilityConnection::new().await else {
        return primary_selection_or_unavailable("unknown");
    };
    let connection = atspi.connection();
    let Ok(root) = atspi.root_accessible_on_registry().await else {
        return primary_selection_or_unavailable("unknown");
    };
    let Ok(applications) = root.get_children().await else {
        return primary_selection_or_unavailable("unknown");
    };

    let mut active_roots = Vec::new();
    let mut other_roots = Vec::new();
    for application in applications {
        let Ok(proxy) = application.into_accessible_proxy(connection).await else {
            continue;
        };
        let application_name = proxy.name().await.unwrap_or_else(|_| "unknown".to_owned());
        if application_name == "flow-linux" {
            continue;
        }
        let Ok(frames) = proxy.get_children().await else {
            continue;
        };
        for frame in frames {
            if frame.is_null() {
                continue;
            }
            let Ok(frame_proxy) = frame.clone().into_accessible_proxy(connection).await else {
                continue;
            };
            if frame_proxy
                .get_state()
                .await
                .is_ok_and(|state| state.contains(State::Active))
            {
                active_roots.push(SearchRoot {
                    application_name: application_name.clone(),
                    object: frame,
                });
            } else {
                other_roots.push(SearchRoot {
                    application_name: application_name.clone(),
                    object: frame,
                });
            }
        }
    }

    let mut found_text_interface = false;
    let active_application_names = active_roots
        .iter()
        .map(|root| root.application_name.as_str())
        .collect::<Vec<_>>()
        .join(", ");
    debug_active_applications(&active_application_names);

    // The compositor owns the primary selection and updates it whenever the
    // user highlights text. Prefer it when available because some AT-SPI
    // bridges leave multiple windows marked Active and retain stale ranges.
    if let Some(text) = read_primary_selection() {
        let application_name = if active_application_names.is_empty() {
            "unknown"
        } else {
            &active_application_names
        };
        debug_selection("primary selection", application_name, &text);
        return Ok(text);
    }

    for root in active_roots {
        let result = selected_text_in_window(&atspi, root.object).await;
        found_text_interface |= result.found_text_interface;
        if let Some(text) = result.text {
            debug_selection("AT-SPI", &root.application_name, &text);
            return Ok(text);
        }
    }

    // Newly registered applications are usually the most recently used, which
    // is the best available ordering once a tray interaction has moved focus.
    other_roots.reverse();
    for root in other_roots {
        let result = selected_text_in_window(&atspi, root.object).await;
        found_text_interface |= result.found_text_interface;
        if let Some(text) = result.text {
            debug_selection("AT-SPI fallback", &root.application_name, &text);
            return Ok(text);
        }
    }

    Err(if found_text_interface {
        SelectionError::NoSelectedText
    } else {
        SelectionError::Unavailable
    })
}

fn primary_selection_or_unavailable(application_name: &str) -> Result<String, SelectionError> {
    let text = read_primary_selection().ok_or(SelectionError::Unavailable)?;
    debug_selection("primary selection", application_name, &text);
    Ok(text)
}

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
fn debug_active_applications(application_names: &str) {
    if debug_enabled() {
        let names = if application_names.is_empty() {
            "none"
        } else {
            application_names
        };
        eprintln!("[Flow selection] active app(s): {names}");
    }
}

#[cfg(not(debug_assertions))]
fn debug_active_applications(_: &str) {}

#[cfg(debug_assertions)]
fn debug_selection(source: &str, application_name: &str, text: &str) {
    if debug_enabled() {
        eprintln!("[Flow selection] source={source}; app={application_name}; text={text:?}");
    }
}

#[cfg(not(debug_assertions))]
fn debug_selection(_: &str, _: &str, _: &str) {}

/// Reads the compositor's primary selection without touching the normal
/// clipboard. KDE Wayland exposes this through ext-data-control even though
/// Qt's QClipboard reports primary selections as unsupported on Wayland.
fn read_wayland_primary_selection() -> Option<String> {
    if std::env::var_os("WAYLAND_DISPLAY").is_none() {
        return None;
    }
    let (pipe, _) = get_contents(ClipboardType::Primary, Seat::Unspecified, MimeType::Text).ok()?;
    let maximum_bytes = MAXIMUM_SELECTION_CHARACTERS.saturating_mul(4) + 1;
    let mut bytes = Vec::new();
    pipe.take(maximum_bytes as u64)
        .read_to_end(&mut bytes)
        .ok()?;
    let selected = String::from_utf8(bytes).ok()?;
    (!selected.trim().is_empty()).then_some(selected)
}

fn read_primary_selection() -> Option<String> {
    if std::env::var_os("WAYLAND_DISPLAY").is_some() {
        read_wayland_primary_selection()
    } else {
        read_x11_primary_selection()
    }
}

fn read_x11_primary_selection() -> Option<String> {
    if std::env::var_os("DISPLAY").is_none() {
        return None;
    }
    let clipboard = x11_clipboard::Clipboard::new().ok()?;
    let bytes = clipboard
        .load(
            clipboard.getter.atoms.primary,
            clipboard.getter.atoms.utf8_string,
            clipboard.getter.atoms.property,
            Duration::from_millis(250),
        )
        .ok()?;
    let selected = String::from_utf8(bytes).ok()?;
    let selected = selected.trim_end_matches('\0').to_owned();
    (!selected.trim().is_empty()).then_some(selected)
}

#[derive(Default)]
struct SearchResult {
    text: Option<String>,
    found_text_interface: bool,
}

async fn selected_text_in_window(
    atspi: &atspi_connection::AccessibilityConnection,
    root: atspi_common::ObjectRefOwned,
) -> SearchResult {
    let connection = atspi.connection();
    let Ok(root_proxy) = root.clone().into_accessible_proxy(connection).await else {
        return SearchResult::default();
    };

    // Collection performs the potentially large tree search inside the
    // application. This avoids exhausting the traversal bound on toolbars and
    // menus before reaching an editor or document.
    if let Ok(proxies) = root_proxy.proxies().await
        && let Ok(collection) = proxies.collection().await
    {
        let rule = ObjectMatchRule::builder()
            .interfaces([Interface::Text], MatchType::All)
            .build();
        if let Ok(objects) = collection
            .get_matches(rule, SortOrder::Canonical, 0, true)
            .await
            && !objects.is_empty()
        {
            for object in objects {
                if let Some(text) = explicit_selection(atspi, object).await {
                    return SearchResult {
                        text: Some(text),
                        found_text_interface: true,
                    };
                }
            }
            return SearchResult {
                text: None,
                found_text_interface: true,
            };
        }
    }

    let mut result = SearchResult::default();
    let mut stack = vec![root];
    let mut remaining = MAXIMUM_VISITED_ELEMENTS_PER_WINDOW;
    while let Some(object) = stack.pop() {
        if remaining == 0 {
            break;
        }
        remaining -= 1;
        if object.is_null() {
            continue;
        }
        let Ok(proxy) = object.clone().into_accessible_proxy(connection).await else {
            continue;
        };
        if let Ok(proxies) = proxy.proxies().await
            && proxies.text().await.is_ok()
        {
            result.found_text_interface = true;
            if let Some(text) = explicit_selection(atspi, object).await {
                result.text = Some(text);
                return result;
            }
        }
        if let Ok(children) = proxy.get_children().await {
            stack.extend(children.into_iter().rev());
        }
    }
    result
}

async fn explicit_selection(
    atspi: &atspi_connection::AccessibilityConnection,
    object: atspi_common::ObjectRefOwned,
) -> Option<String> {
    let proxy = object
        .into_accessible_proxy(atspi.connection())
        .await
        .ok()?;
    let proxies = proxy.proxies().await.ok()?;
    let text_proxy = proxies.text().await.ok()?;
    let count = text_proxy.get_n_selections().await.ok()?;
    for index in 0..count {
        let (start, end) = text_proxy.get_selection(index).await.ok()?;
        if end <= start {
            continue;
        }
        let text = text_proxy.get_text(start, end).await.ok()?;
        if !text.trim().is_empty() {
            return Some(text);
        }
    }
    None
}
