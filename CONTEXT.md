# Flow

Flow is a menu-bar text-to-speech reader: it captures selected text and reads
it aloud with sentence-level language routing. This context covers the shared
product language across the macOS and Linux applications.

## Language

### Capture and playback

**Selection**:
Text captured from the focused application through Accessibility.
_Avoid_: clipboard text, copied text

**Speech source**:
The chosen synthesis provider: system voices, local Piper models, Azure
Speech, or Google Cloud Text-to-Speech.
_Avoid_: engine, backend, TTS provider

**BYOK credential**:
The person's own cloud API key or subscription key, stored in the platform
credential vault (macOS Keychain) and never in settings files.
_Avoid_: token, secret, config key

### Language Flow

**Language Flow**:
The feature that detects each sentence's language locally and routes it to a
configured voice.
_Avoid_: auto-language, language detection mode

**Language route**:
The per-language configuration pairing a language with a voice and speech
rate.
_Avoid_: language mapping, voice route

**Default route**:
The language route used for sentences whose language is undetected or has no
configured route.

**Language check**:
The confirmation step that asks before playback when detection is uncertain or
a detected language is not enabled.
_Avoid_: language prompt, review dialog

### Voice modes

**Multilingual mode**:
One retained voice that receives a per-sentence language tag.

**Per-language mode**:
Each language route uses its own configured voice and rate.
