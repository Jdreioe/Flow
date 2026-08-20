# Flow for Linux

Flow is a Qt 6 and Rust system-tray reader. Select text in another application,
then use Flow's global shortcut to hear it. System voices stay on-device;
Azure neural voices are optional and use the person's own Azure Speech resource.

## Requirements

- Rust 1.88 or newer
- Qt 6.6 or newer with Core, Gui, Widgets, QML/Quick Controls, and Multimedia
  development packages
- Speech Dispatcher and at least one speech module for system voices
- AT-SPI 2 for selected-text access
- `xdg-desktop-portal` with a backend that supports Global Shortcuts

Package names differ by distribution. On Fedora, the Qt development packages
include `qt6-qtbase-devel`, `qt6-qtdeclarative-devel`, `qt6-qtmultimedia-devel`,
and `speech-dispatcher-espeak-ng`.

On openSUSE, the runtime packages are `speech-dispatcher`,
`speech-dispatcher-module-espeak`, and `libspeechd2`.

## Run it

```sh
cargo run -p flow-linux
```

The desktop may show a one-time portal dialog asking you to confirm the global
shortcut. The default request is Alt-Super-R; two alternatives are available in
Settings. If the desktop does not provide the Global Shortcuts portal, click the
tray icon and choose **Read selected text**.

For system speech, ensure Speech Dispatcher has a working output module. Flow
prefers `espeak-ng`, falls back to another installed module, and starts the
per-user Speech Dispatcher service automatically when needed.

To install a release build for the current user:

```sh
cargo install --path linux
install -Dm644 linux/io.github.jdreioe.flow.desktop \
  "$HOME/.local/share/applications/io.github.jdreioe.flow.desktop"
```

## Selection access

Flow first asks AT-SPI for explicit selection ranges in the active
application's accessibility tree. For terminals and custom-rendered editors,
it falls back to the desktop's primary selection, which represents currently
highlighted text. It does not synthesize copy keystrokes, replace the normal
clipboard, or read a document's complete text value. Protected fields and
applications that expose neither source cannot be read by Flow.

For selection troubleshooting, run a debug build with
`FLOW_DEBUG_SELECTION=1 cargo run`. This prints the detected application,
capture source, and selected text to the terminal. Selected text can be
sensitive, so this logging is opt-in and disabled in release builds.

The accessibility traversal is bounded to keep a malformed tree from delaying
the hotkey. Browser accessibility support varies; current Firefox and Chromium
builds may need accessibility to be enabled by the desktop before they expose
web content.

## Azure Speech

Azure is optional. In **Settings > Azure Speech**, enter either a Speech region
(for example `westeurope`) or its HTTPS speech endpoint and a subscription key.
Flow stores the key in the Linux desktop keyring through Secret Service. The key
is never written to Flow's settings file.

When Azure is selected, only text explicitly requested for playback is sent to
the configured Speech resource. Voice discovery and synthesis use Azure's Text
to Speech REST API. Synthesized audio is held in a temporary file only for the
duration of playback and is then deleted.

## Behavior parity

- Global shortcut and tray-menu activation
- AT-SPI selected-text capture with a non-destructive primary-selection fallback
- System and Azure voices, speech rate, pause/resume, stop, and test playback
- Sentence-level on-device language detection across Flow's ten languages
- Language review when detection is uncertain or a language is not configured
- Per-language system/Azure routing and Azure multilingual mode
- Configurable popup dismissal and same-selection behavior
- A roughly ten-minute selection limit and no reading history

Linux uses the XDG portal, AT-SPI, Secret Service, Speech Dispatcher, and Qt
Multimedia where macOS uses Carbon, Accessibility, Keychain, AVFoundation, and
Natural Language. The platform adapters differ; the user-visible model does not.
