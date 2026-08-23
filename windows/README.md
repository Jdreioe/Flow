# Flow for Windows

Flow reads selected text aloud on Windows using UI Automation for capture,
WinRT speech synthesis for system voices, and the same Azure Speech and Google
Cloud Text-to-Speech engines as the other platforms.

## Platform integration

- **Selection**: UI Automation `TextPattern` selection ranges from the focused
  element and its ancestors. Flow never touches the clipboard.
- **Global shortcuts**: `RegisterHotKey` with Alt+Win+R, Alt+Win+Space, or
  Ctrl+Alt+R presets.
- **BYOK credentials**: Azure subscription keys and Google Cloud API keys are
  stored in Windows Credential Manager through the `keyring` vault.
- **System voices**: WinRT `SpeechSynthesizer` voices streamed through
  `MediaPlayer`. Route language tags select the voice.
- **Settings**: JSON under `%APPDATA%\jdreioe\Flow\settings.json`, sharing the
  `flow-core` model with Linux.
- **Updates**: Velopack checks a GitHub Releases feed from the tray menu,
  downloads delta packages, and applies them on restart (`vpk` packages each
  release; see `docs/adr/0004-adopt-velopack-for-windows-updates.md`).

## Building

Requirements:

1. Rust (MSVC toolchain) via [rustup](https://rustup.rs).
2. Visual Studio 2022 Build Tools with the "Desktop development with C++"
   workload (MSVC compiler and Windows SDK).
3. Qt 6 (MSVC 64-bit build) installed, e.g. under `C:\Qt\6.*`.

Point the build at Qt before compiling:

```powershell
$env:CMAKE_PREFIX_PATH = "C:\Qt\6.8.0\msvc2022_64"
cargo run -p flow-windows
```

The first build compiles the Qt bridge and can take several minutes.

## Known gaps

- The installer is unsigned, so Windows SmartScreen shows a one-time
  "Windows protected your PC" notice; users choose "More info" > "Run anyway".
  Signing is ready to enable via the `VPK_SIGNPARAMS` environment variable on
  `scripts/package-velopack.ps1`.

- The tray icon currently falls back to the system default glyph; shipping a
  Flow `.ico`/`.png` through a Qt resource file is still pending.
- Selection capture relies on apps exposing UI Automation text patterns
  (browsers, Office, Notepad, most editors do). Legacy apps without UIA
  support report "does not expose its selected text".
