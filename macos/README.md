# Flow for macOS

Flow is a native macOS menu-bar reader. Select text in an application, then
press Flow's global hotkey to hear it. System voices are the default; Azure and
Google Cloud voices are available with the person's own cloud credentials.

## Run it

Open [Flow.xcodeproj](Flow.xcodeproj) in Xcode. Under **Signing &
Capabilities**, select an Apple development team for Flow, then run the `Flow`
scheme. macOS ties Accessibility permission to the signed application identity,
so an unsigned or ad-hoc build is not a reliable way to test selected-text
capture.

After choosing a team, a command-line build can use that same identity:

```sh
xcodebuild -project macos/Flow.xcodeproj \
  -scheme Flow \
  -configuration Debug \
  -derivedDataPath /tmp/flow-derived-data \
  build
```

The built application is at
`/tmp/flow-derived-data/Build/Products/Debug/Flow.app`.

## Updates

Flow uses Sparkle for signed macOS updates. The feed is attached to the latest
GitHub release as `appcast.xml`, and each release archive is signed with the
EdDSA key stored in the release machine's login Keychain. Only the matching
public key is included in `Flow.app`.

Generate the key once, from Sparkle's `bin/generate_keys` tool. Never commit the
private key. `scripts/release-macos.sh` builds the app, notarizes it, creates the
signed appcast, and uploads both the ZIP and `appcast.xml`. The script applies
the requested marketing version and increments the build version in its working
tree before building.

## GitHub release workflow

The `Release Flow` action builds macOS, Linux, and Windows in parallel, then
publishes every package to one GitHub Release. Run it manually and enter a
`major.minor.patch` version.

The macOS job needs these repository secrets:

- `MACOS_CERTIFICATE_BASE64`: the Developer ID Application certificate and
  private key exported as a password-protected `.p12`, then base64 encoded.
- `MACOS_CERTIFICATE_PASSWORD`: the `.p12` export password.
- `APPLE_ID`: the Apple ID used for notarization.
- `APPLE_TEAM_ID`: the Apple Developer team ID.
- `APPLE_APP_PASSWORD`: an app-specific password for notarization.
- `SPARKLE_ED_PRIVATE_KEY`: the existing Sparkle EdDSA private key. The job
  passes it to `generate_appcast` through standard input. Sparkle's
  `generate_keys -x private-key-file` command exports the existing key for
  adding to this secret.

`VPK_SIGNPARAMS` is optional. When configured, the Windows job passes it to
Velopack for installer signing.

## First use

1. Open Flow from the build product or Xcode.
2. Open Flow's menu-bar item and choose **Settings**.
3. Choose **Allow Accessibility access**, then enable Flow in macOS Privacy &
   Security > Accessibility.
4. Select text in an application that exposes its selection to macOS
   accessibility, then press Option-Command-R.

Flow ships as an agent-style menu-bar app. It has no Dock icon while running.
The default hotkey and the two alternatives are configurable in Settings.

## Azure Speech setup

Azure is optional. In **Settings > Speech**, choose **Azure Speech**, then add
either your Azure Speech region (for example `westeurope`) or its HTTPS speech
endpoint and its subscription key. Flow stores that key in this Mac's Keychain
and never writes it to application settings.

The setup screen links to Flow's free (F0) Azure Speech resource template and
to the Azure Portal page listing the person's existing Speech resources.

When Azure is selected, the text you ask Flow to read is sent to your Azure
Speech resource for synthesis. System voices remain on-device. Use **Play test
voice** in Settings to confirm an Azure configuration without capturing text
from another application.

Azure requests use the standard [Text to Speech REST API](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/rest-text-to-speech).
After saving an Azure resource, Flow loads that resource's current Voice List.
The multilingual selector shows multilingual voices by Azure short name. Each
per-language route shows voices whose primary or secondary locale supports that
language.

## Google Cloud Text-to-Speech setup

Google Cloud is optional and uses the person's own API key:

1. In **Settings > Speech**, choose **Google Cloud voice**.
2. Follow Flow's link to enable the Cloud Text-to-Speech API in a Google Cloud
   project with billing enabled.
3. Create an API key and apply an API restriction allowing only the Cloud
   Text-to-Speech API.
4. Paste the key into Flow and choose **Save Google configuration**.

Flow stores the key in this Mac's Keychain and sends it in the
`x-goog-api-key` header, so it is not placed in a URL or settings file. After
setup, Flow loads Google's current voice list. Each Language Flow route can use
Google's default voice for its language or a named voice, with an independent
speech rate.

Google's synchronous API limits each text input to 5,000 bytes. Flow splits
long selections at Unicode-safe boundaries and plays the returned MP3 segments
in order. Only text explicitly requested for playback is sent to Google Cloud;
generated audio is kept in memory for that playback.

Flow uses Google's [`voices.list`](https://cloud.google.com/text-to-speech/docs/reference/rest/v1/voices/list)
and [`text.synthesize`](https://cloud.google.com/text-to-speech/docs/reference/rest/v1/text/synthesize)
REST methods. Google's [API key guidance](https://cloud.google.com/docs/authentication/api-keys-best-practices)
explains key restrictions and rotation.

## v1 behavior

- Captures selected text through macOS Accessibility before showing its popup.
- Uses a non-activating playback popup so the source application keeps focus.
- Reads with selectable system voices through `AVSpeechSynthesizer`, or opt-in
  Azure and Google Cloud voices through their REST APIs.
- Includes **Language Flow**: add a language and voice in Settings, and Flow
  detects each sentence locally before choosing the configured system voice.
  It asks before playback when detection is uncertain or a detected language is
  not enabled.
- Azure multilingual mode retains one Azure voice and sends a language tag for
  each sentence. Azure per-language mode uses the configured voice and rate for
  each language route.
- Google Cloud mode uses the configured voice and rate for each language route,
  falling back to Google's default voice when no named voice is selected.
- Keeps captured text in memory only while the popup is visible.
- Limits selections to roughly ten minutes of speech.
- Mixes with other applications' audio. macOS audio ducking is explicitly not
  implemented in v1.
- Does not include clipboard fallback, document parsing, history, or saved
  passages.
