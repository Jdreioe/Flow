use std::{io::Read, time::Duration};

use atspi_common::{Interface, MatchType, ObjectMatchRule, ObjectRefOwned, SortOrder, State};
use atspi_connection::set_session_accessibility;
use atspi_proxies::{accessible::ObjectRefExt, proxy_ext::ProxyExt};
use futures_util::StreamExt;
use thiserror::Error;
use wl_clipboard_rs::paste::{ClipboardType, MimeType, Seat, get_contents};

use flow_core::model::MAXIMUM_SELECTION_CHARACTERS;

const MAXIMUM_VISITED_ELEMENTS_PER_WINDOW: usize = 2_000;

/// Concurrent AT-SPI round trips per window sweep. Browsers expose thousands
/// of text nodes; serial queries take seconds, parallel ones stay fast.
const CONCURRENT_NODE_QUERIES: usize = 16;

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
/// selection ranges are resolved. The focused window is checked first, then
/// other active windows, because AT-SPI reflects the user's current selection
/// even when it was made with the keyboard. The compositor's primary
/// selection is only a fallback: many applications never update it for
/// keyboard selections, so it can hold a stale value indefinitely.
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

    let mut focused_roots = Vec::new();
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
            let search_root = SearchRoot {
                application_name: application_name.clone(),
                object: frame,
            };
            let state = frame_proxy.get_state().await.unwrap_or_default();
            if state.contains(State::Focused) {
                focused_roots.push(search_root);
            } else if state.contains(State::Active) {
                active_roots.push(search_root);
            } else {
                other_roots.push(search_root);
            }
        }
    }

    let mut found_text_interface = false;
    let active_application_names = focused_roots
        .iter()
        .chain(&active_roots)
        .map(|root| root.application_name.as_str())
        .collect::<Vec<_>>()
        .join(", ");
    debug_active_applications(&active_application_names);

    // The compositor's primary selection is read up front because it is the
    // fastest signal available, but the AT-SPI search wins if it answers
    // within the grace period: accessibility reflects the user's current
    // selection even when it was made with the keyboard, while the primary
    // selection can hold a stale value indefinitely. All windows join the
    // race because several Wayland apps (Firefox, Electron) never mark their
    // windows Active or Focused over AT-SPI, so restricting the race to
    // active windows would always fall through to a stale primary value.
    other_roots.reverse();
    let primary_text = read_primary_selection();
    let search = search_windows(
        &atspi,
        focused_roots
            .iter()
            .chain(&active_roots)
            .chain(&other_roots),
    );
    tokio::pin!(search);
    let mut search_found_text_interface = false;
    let atspi_text = if primary_text.is_some() {
        let grace = tokio::time::sleep(Duration::from_millis(750));
        tokio::pin!(grace);
        loop {
            tokio::select! {
                result = &mut search => {
                    search_found_text_interface = result.found_text_interface;
                    break result.text;
                }
                _ = &mut grace => break None,
            }
        }
    } else {
        let result = search.await;
        search_found_text_interface = result.found_text_interface;
        result.text
    };
    found_text_interface |= search_found_text_interface;
    if let Some(text) = atspi_text {
        debug_selection("AT-SPI", "focused or active", &text);
        return Ok(text);
    }
    if let Some(text) = primary_text {
        let application_name = if active_application_names.is_empty() {
            "unknown"
        } else {
            &active_application_names
        };
        debug_selection("primary selection", application_name, &text);
        return Ok(text);
    }

    Err(if found_text_interface {
        SelectionError::NoSelectedText
    } else {
        SelectionError::Unavailable
    })
}

/// Walks the given windows in priority order and returns the first explicit
/// text selection, plus whether any window exposed a text interface at all.
async fn search_windows<'a, I>(
    atspi: &atspi_connection::AccessibilityConnection,
    roots: I,
) -> SearchResult
where
    I: Iterator<Item = &'a SearchRoot>,
{
    let mut result = SearchResult::default();
    for root in roots {
        let window = selected_text_in_window(atspi, root.object.clone()).await;
        result.found_text_interface |= window.found_text_interface;
        if let Some(text) = window.text {
            result.text = Some(text);
            return result;
        }
    }
    result
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

/// Enables the accessibility bus as early as possible. Chromium and Electron
/// applications only build their accessibility tree when assistive technology
/// is already enabled at their launch, so Flow turns it on during startup —
/// the Linux counterpart of preparing apps on macOS.
pub async fn enable_accessibility() {
    let _ = set_session_accessibility(true).await;
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

/// Breadth-first sweep of a window's accessibility tree, querying nodes in
/// parallel. The Collection shortcut is tried first because some apps answer
/// it instantly, but Firefox's implementation returns nothing, so the sweep
/// is what actually finds selections in browsers.
async fn selected_text_in_window(
    atspi: &atspi_connection::AccessibilityConnection,
    root: atspi_common::ObjectRefOwned,
) -> SearchResult {
    let connection = atspi.connection();
    let Ok(root_proxy) = root.clone().into_accessible_proxy(connection).await else {
        return SearchResult::default();
    };

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
            let result = first_selection(atspi, objects.into_iter()).await;
            if result.text.is_some() || result.found_text_interface {
                return result;
            }
        }
    }

    let mut result = SearchResult::default();
    let mut remaining = MAXIMUM_VISITED_ELEMENTS_PER_WINDOW;
    let mut level = vec![root];
    while remaining > 0 && !level.is_empty() {
        remaining = remaining.saturating_sub(level.len());
        let outcomes: Vec<((bool, Option<String>), Vec<ObjectRefOwned>)> =
            futures_util::stream::iter(level.drain(..).filter(|object| !object.is_null()))
                .map(|object| {
                    let connection = connection.clone();
                    async move {
                        let selection = node_selection(&connection, object.clone()).await;
                        let children = match object.into_accessible_proxy(&connection).await {
                            Ok(proxy) => proxy.get_children().await.unwrap_or_default(),
                            Err(_) => Vec::new(),
                        };
                        (selection, children)
                    }
                })
                .buffered(CONCURRENT_NODE_QUERIES)
                .collect()
                .await;
        let mut next_level = Vec::new();
        for ((has_text, selection), children) in outcomes {
            result.found_text_interface |= has_text;
            if result.text.is_none() {
                result.text = selection;
            }
            next_level.extend(children);
        }
        if result.text.is_some() {
            return result;
        }
        level = next_level;
    }
    result
}

/// First non-empty selection among the given objects, queried in parallel
/// while preserving their order.
async fn first_selection<I>(
    atspi: &atspi_connection::AccessibilityConnection,
    objects: I,
) -> SearchResult
where
    I: Iterator<Item = atspi_common::ObjectRefOwned>,
{
    let connection = atspi.connection();
    let outcomes: Vec<(bool, Option<String>)> =
        futures_util::stream::iter(objects.filter(|object| !object.is_null()))
            .map(|object| {
                let connection = connection.clone();
                async move { node_selection(&connection, object).await }
            })
            .buffered(CONCURRENT_NODE_QUERIES)
            .collect()
            .await;
    let mut result = SearchResult::default();
    for (has_text, selection) in outcomes {
        result.found_text_interface |= has_text;
        if result.text.is_none() {
            result.text = selection;
        }
    }
    result
}

/// Whether an object exposes a text interface and, if so, its first
/// non-empty selection. Selections that only contain object-replacement
/// characters are embedded graphics or widgets, not readable text.
async fn node_selection(
    connection: &zbus::Connection,
    object: atspi_common::ObjectRefOwned,
) -> (bool, Option<String>) {
    let Ok(proxy) = object.into_accessible_proxy(connection).await else {
        return (false, None);
    };
    let Ok(proxies) = proxy.proxies().await else {
        return (false, None);
    };
    let Ok(text_proxy) = proxies.text().await else {
        return (false, None);
    };
    let Ok(count) = text_proxy.get_n_selections().await else {
        return (true, None);
    };
    for index in 0..count {
        let Ok((start, end)) = text_proxy.get_selection(index).await else {
            continue;
        };
        if end <= start {
            continue;
        }
        let Ok(text) = text_proxy.get_text(start, end).await else {
            continue;
        };
        if has_readable_content(&text) {
            return (true, Some(text));
        }
    }
    (true, None)
}

fn has_readable_content(text: &str) -> bool {
    text.chars()
        .any(|character| character != '\u{FFFC}' && !character.is_whitespace())
}
