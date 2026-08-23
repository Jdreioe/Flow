# Adopt Velopack for Windows updates

Windows shipped with a hand-rolled update path: an MSIX sideload package signed
with a self-signed certificate that users had to trust manually, plus a
`fetch_latest_release_message` check that compared GitHub release tags as plain
strings and could only point users at a download page. Like the macOS updater
that ADR 0002 replaced, this code owns installer edge cases (certificate
rollover, partial installs, version comparison) without being a deliberate
choice.

We decided to replace both with [Velopack](https://velopack.io), using its
official Rust crate in `flow-windows` and the `vpk` CLI in the release
workflow.

Why: Velopack handles install, delta updates, rollback, restart coordination,
and forward-only version application out of the box, and it is written in Rust —
the same language as Flow for Windows. It hosts its update feed as static files,
so GitHub Releases keeps working with no new infrastructure. Cost accepted: each
release needs .NET SDK 8 on the build runner for `vpk`, and existing MSIX
installs migrate by downloading the Velopack installer once.

The hand-rolled checker (`UPDATE_API`, `LatestRelease`,
`fetch_latest_release_message`) and `scripts/package-msix.ps1` are deleted in
the same pass — no release ships with both update paths. The feed is published
to GitHub Releases (`releases.win.json` + packages per release), and the app
reads it through an `HttpSource`.

## Considered options

- **Keep and audit the MSIX sideload**: rejected — self-signed certificates
  train users to bypass security warnings, and MSIX gives no delta updates.
- **WinSparkle**: rejected — solid Sparkle analog, but it only detects and
  downloads; it still hands users an installer to run, and it adds a C++
  dependency to a Rust crate.
- **MSIX Store distribution**: rejected — Store review cadence conflicts with
  release-candidate iterations, and BYOK speech apps risk Store policy friction.
- **Delete in-app updates**: rejected — same reasoning as ADR 0002: users of a
  tray reader rarely relaunch; update prompts are the discovery path.
