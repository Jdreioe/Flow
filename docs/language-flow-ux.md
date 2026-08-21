# Language Flow UX spec

Shared interaction spec for the simplified Language Flow, implemented
identically on macOS and Linux. Both platforms review UI changes against this
document. Long-term goal (out of scope here): interaction decisions move into
the shared core and platforms render dumbly.

## Core model

Replaces three concepts: `AzureVoiceMode` (multilingual vs per-language), the
explicit default-language picker, and the "Let Flow switch languages" toggle.

- One **fallback voice** reads every sentence that is undetected or has no
  configured route.
- Zero or more **language routes**: a language paired with a voice and an
  optional speech-rate override.
- Language Flow is always on. There is no on/off switch; removing routes is
  how a user approaches plain single-voice playback.
- Per-route rate overrides exist but are visually secondary to one global
  rate control.

## Playback

**Never block.** The language check state (macOS `PlaybackPopup.swift`
language-check view, Linux `Main.qml` language-check frames) is deleted in
full. Playback starts immediately using best-guess routing.

Correction is post-hoc and **silent until wrong**:

- No detection UI appears while detection matches configured routing.
- A persistent **Language…** button sits next to Stop/Pause. It expands a
  compact section in the popup listing languages detected so far; picking a
  route for a language applies to every remaining sentence of that language.
  Because cloud speech sources synthesize the whole selection into one
  stream, applying a route replays the selection from its start with the
  new routing.
- When the current sentence's detected language has no route, an inline chip
  appears: "Reading French with English voice — tap to fix". Tapping creates
  the route with a suggested voice (see below) in one action and playback
  continues. The user can refine the voice later in settings.
- Any mid-playback fix implicitly applies to all future detections of that
  language for the rest of the session. There is no "apply to all" checkbox.

**Popup position:** the playback popup appears centered in the middle of the
screen on both platforms. macOS currently anchors it to the cursor
(`PlaybackPopup.swift:25`) and Linux floats it near the top; both move to
screen-center.

### Word highlighting

- Highlighting renders in the popup preview text only — no overlay windows.
- Word-by-word: already-read text dims, the current word highlights, upcoming
  text stays full contrast.
- Timing comes from engine word-boundary events where available (Azure word
  boundaries; macOS `AVSpeechSynthesizer.willSpeakRangeOfSpeechString`;
  Linux speech-dispatcher word marks). Engines without boundary events fall
  back to estimated timing (character-proportional interpolation).
- Off by default; a toggle lives in Playback settings.

### Language override

- A language picker lives in the playback popup next to the **Language…**
  button, defaulting to **Auto**.
- When a specific language is picked, sentence detection is suspended for
  the current selection: every sentence is read with that language's route.
- If the overridden language has no configured route, playback holds in an
  "awaiting route" state and an inline "Read as" route picker appears in the
  popup; reading starts only once a route is chosen. It never silently falls
  back to the default voice. The chosen route lasts as long as the override.
- Restoring Auto re-runs detection but never blocks: review flags are
  cleared and reading continues immediately (ADR 0003).
- The override lasts until the next capture — nothing sticky survives into
  the following playback. There is no override UI in settings.

## Settings

The Language Flow settings section contains exactly two things:

1. **Fallback voice** picker.
2. **Route list**, plus one add-language affordance.

- Adding a language is one click: choose the language; the route is created
  immediately with a suggested voice.
- Route row collapsed: language name + voice summary line. Expanded: voice
  picker, rate slider, remove button.
- Global rate slider lives outside the route list; per-route rate override is
  only visible inside an expanded route row.

### Voice suggestion

When a route needs a voice automatically (add-language or chip tap): prefer
a matching voice from the same provider as the fallback voice; within that
provider pick the best available match for the locale, deterministically.

## Migration

Silent, no prompt:

- Multilingual users: the Azure multilingual voice becomes the fallback
  voice; existing routes carry over as explicit routes.
- Per-language users: the old default route's language + voice becomes the
  first explicit route; fallback falls back to the Azure multilingual voice
  or first system voice.
- Global rate = old default-route rate.

## Cleanup folded into this effort

- Delete the hardcoded Swift `FlowLanguageOption` enum
  (`macos/Flow/LanguageFlow/LanguageFlow.swift`); use the snapshot-driven
  language list from the shared core, as Linux already does.
- Deduplicate `enable_language` / `add_language` in
  `linux/src/backend.rs`.
- Update stale settings references in `macos/README.md`.

The rebuilt macOS settings window is designed to this spec directly; the
pre-modularization settings UI is not restored.
