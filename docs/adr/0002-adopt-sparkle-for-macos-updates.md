# Adopt Sparkle for macOS updates

Flow shipped with a hand-rolled updater (GitHub releases check, codesign
verification against the team ID, backup-and-swap via a generated shell
script). That code originated as AI-generated scaffolding rather than a
deliberate choice, so we reviewed it as a decision point and decided to
replace it with [Sparkle](https://sparkle-project.org), the standard macOS
auto-update framework.

Why: Sparkle handles EdDSA-signed updates, rollback on failed installs,
delta updates, and sandboxed installs out of the box, and its edge cases are
battle-tested by thousands of apps. Maintaining a bespoke shell-script
installer re-owns those risks forever. Cost accepted: each release needs an
appcast and an EdDSA signature step in the release workflow.

The custom updater (`UpdateChecker`, `UpdateManager`, `UpdateInstaller` in
`macos/Flow/FlowApp.swift`) is deleted in the same pass that introduces
Sparkle — no release ships with both update paths. The feed is hosted on
GitHub Releases via `generate_appcast` (no new infrastructure); existing
installs pick up Sparkle on their next manual download.

## Considered options

- **Keep and audit the custom installer**: rejected — correct today, but every future edge case (partial downloads, interrupted swaps, notarization changes) becomes ours.
- **Delete in-app updates**: rejected — users of a menu-bar reader rarely relaunch; update prompts are the discovery path.
