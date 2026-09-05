# Flow desktop (Linux and Windows)

One Rust application for both OSes, with an iced UI over the shared playback
controller in `src/controller.rs`.

```sh
cargo run -p flow-desktop
```

## Layout

- `src/controller.rs` holds the playback and settings state machine (selection
  handling, language planning, synthesis fan-out). Worker threads post
  `Event`s back to the iced UI; there is no toolkit bridge object.
- `src/audio.rs` plays Azure, Google, and Piper audio through rodio. System
  speech stays native (Speech Dispatcher on Linux, WinRT on Windows).
- `src/selection.rs`, `src/shortcuts.rs`, `src/system_speech.rs`, and
  `src/updates.rs` dispatch to a per-OS module behind one shared interface.
- `src/azure.rs`, `src/google.rs`, `src/settings.rs`, and `src/piper.rs` are
  fully shared.
- The tray icon lives behind the `tray` feature (on by default). Linux uses
  StatusNotifier over D-Bus (ksni) and Windows uses tray-icon, so neither
  side needs system development libraries. Where no StatusNotifier watcher
  runs, the tray silently stays absent and the window plus global shortcut
  keep working.

## Windows notes

Velopack hooks run first in `main`. The icon is embedded by `build.rs` from
`assets/flow.ico`; no Qt or `windeployqt` step is involved. Piper voices work
on both OSes through the same `piper` executable lookup.
