# Flow changelog

## 0.8.0

Language Flow starts reading immediately and is easier to correct when it chooses the wrong voice.

- Read unconfigured languages with the fallback voice instead of waiting for confirmation.
- Add a suggested voice route with one click when the current language sounds wrong.
- Change language routing from the playback popup while reading or paused.
- Replace Azure voice modes and the language-switching toggle with one fallback voice and explicit language routes.

## 0.7.1

Voice selection stays readable and playback stays responsive.

- Hide the multi-speaker voice variants that third-party speech apps register so the system voice list shows one entry per voice.
- Group Google Cloud voices by model family, such as Gemini-TTS, Chirp 3 HD, Studio, Journey, Polyglot, Neural2, and WaveNet.
- Play a sample of any Google Cloud voice before selecting it for a language route.
- Keep the playback popup responsive while words are highlighted, even when many system voices are installed.

## 0.6

Playback is much easier to follow and control.

- Change the playback speed while speech is running.
- Set a different playback speed for each language route.
- See playback progress and seek through the current selection.
- Optionally highlight each spoken word in the source text.
- Override the detected language for a selection and keep that choice until it is cleared.
- Ask for a language route before reading text when Language Flow finds a language that is not configured.

## 0.5

- Improve automatic language selection for mixed-language text.
- Fix issues found in the first releases.

## 0.35

- Check for updates manually and verify that an available release matches the installed app.

## 0.3

- Install signed macOS updates automatically with Sparkle.
- Use Azure Speech or Google Cloud Text-to-Speech alongside macOS system voices.
- Configure cloud speech providers, credentials, voices, and language routes in Settings.

## 0.2

- Read selected text from the macOS menu bar with a global hotkey.
- Route each sentence to the voice configured for its detected language.
- Configure a default voice and additional language voices.
- Choose the global hotkey used to start reading.

## 0.1

- First release of Flow for macOS.
- Read selected text with Azure Speech or a macOS system voice.
