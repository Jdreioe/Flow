# Never block playback on language detection

Language Flow's language check intercepted playback whenever sentence
detection was uncertain or the detected language had no configured route,
requiring 3–5 interactions before any audio played. Configuring a new route
took ~7 interactions. We decided to remove the blocking check entirely and
replace it with post-hoc correction during playback, and to collapse the
configuration model (voice mode, default route, on/off toggle) into a single
fallback voice plus explicit language routes.

Why: people notice wrong-language speech by hearing it, so the right moment
to offer a fix is after playback starts, not before. Blocking cost certainty
(the user must judge a written snippet) for latency; correction costs at most
one mis-voiced sentence, bounded by how long the user listens before tapping
the fix affordance. Dropping the voice-mode concept removes a
synthesis-strategy decision users shouldn't have to make: configured routes
use their voice, everything else uses the fallback voice — the modes fall out
of that rule.

The full interaction contract lives in
[`docs/language-flow-ux.md`](../language-flow-ux.md), which is the shared
spec both platforms implement and review against.

## Considered options

- **Keep the check but streamline it**: rejected — still blocks audio behind a judgment call the user is worse at making than their own ears.
- **Opt-in "confirm uncertain languages" setting**: rejected — default-off settings nobody enables are their own UX cost; reintroduce only with evidence the post-hoc model fails.
