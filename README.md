# Flow

Flow is a lightweight desktop app that reads highlighted text aloud. It has
native applications for macOS and Linux, including system, Azure, and Google
Cloud voices, sentence-level language routing, and global shortcuts.

## Repository layout

- `core/` contains platform-independent settings and language-planning logic.
- `linux/` contains the Rust and Qt 6 application.
- `macos/` contains the Swift and SwiftUI application.

The Linux app consumes `flow-core` directly. The next sharing boundary is a
small, versioned Swift bridge to that core; it should be added with matching
cross-platform contract tests rather than coupling Swift to Rust's internal
ABI. Platform integration—selection, shortcuts, secure credentials, settings
storage, and speech engines—stays native.

## Linux

```sh
cargo run -p flow-linux
```

See [`linux/README.md`](linux/README.md) for system dependencies and setup.

## macOS

Open `macos/Flow.xcodeproj` in Xcode. See
[`macos/README.md`](macos/README.md) for signing and accessibility setup.

## License

Flow is licensed under GPL-3.0-only.
