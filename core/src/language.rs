use std::sync::OnceLock;

use lingua::{Language, LanguageDetector, LanguageDetectorBuilder};
use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

use crate::model::{LanguageRoute, Settings};

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Sentence {
    pub id: Uuid,
    pub text: String,
    pub detected_language_tag: Option<String>,
    pub route: LanguageRoute,
    pub needs_review: bool,
    pub detected_but_unconfigured: bool,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub sentences: Vec<Sentence>,
}

impl Plan {
    pub fn needs_language_check(&self) -> bool {
        self.sentences.iter().any(|sentence| sentence.needs_review)
    }

    /// Copy of the plan with every review flag cleared, for paths that must
    /// never block playback (see ADR 0003).
    pub fn without_review(&self) -> Plan {
        Plan {
            sentences: self
                .sentences
                .iter()
                .map(|sentence| Sentence {
                    needs_review: false,
                    detected_but_unconfigured: false,
                    ..sentence.clone()
                })
                .collect(),
        }
    }
}

pub fn single_sentence(text: &str, settings: &Settings) -> Plan {
    Plan {
        sentences: vec![Sentence {
            id: Uuid::new_v4(),
            text: text.into(),
            detected_language_tag: Some(settings.default_language_tag.clone()),
            route: settings.default_language_route(),
            needs_review: false,
            detected_but_unconfigured: false,
        }],
    }
}

pub fn plan(text: &str, settings: &Settings) -> Plan {
    detected_plan(text, settings)
}

/// Plans a selection with sentence detection suspended: every sentence is
/// read with the override language's route (falling back to the default
/// route when that language is not configured) and never needs review.
pub fn plan_with_override(text: &str, settings: &Settings, override_tag: Option<&str>) -> Plan {
    let Some(tag) = override_tag else {
        return detected_plan(text, settings);
    };
    let route = settings
        .language_route(tag)
        .unwrap_or_else(|| settings.default_language_route());
    let mut sentences = Vec::new();
    for raw_sentence in text.split_sentence_bounds() {
        let sentence = raw_sentence.trim();
        if sentence.is_empty() {
            continue;
        }
        sentences.push(Sentence {
            id: Uuid::new_v4(),
            text: sentence.into(),
            detected_language_tag: Some(tag.to_owned()),
            route: route.clone(),
            needs_review: false,
            detected_but_unconfigured: false,
        });
    }
    if sentences.is_empty() {
        Plan {
            sentences: vec![Sentence {
                id: Uuid::new_v4(),
                text: text.into(),
                detected_language_tag: Some(tag.to_owned()),
                route,
                needs_review: false,
                detected_but_unconfigured: false,
            }],
        }
    } else {
        Plan { sentences }
    }
}

fn detected_plan(text: &str, settings: &Settings) -> Plan {
    let detector = detector();
    let mut sentences = Vec::new();

    for raw_sentence in text.split_sentence_bounds() {
        let sentence = raw_sentence.trim();
        if sentence.is_empty() {
            continue;
        }
        let confidence_values = detector.compute_language_confidence_values(sentence);
        let detected_language = confidence_values.first().map(|(language, _)| *language);
        // Short Scandinavian sentences are often ambiguous. Prefer a
        // configured Scandinavian candidate, but never substitute an
        // unrelated configured language for the detector's leading result.
        let configured = confidence_values.iter().find_map(|(language, _)| {
            let Some(detected_language) = detected_language else {
                return None;
            };
            if !shares_automatic_language_group(detected_language, *language) {
                return None;
            }
            let tag = language_tag(*language);
            settings.language_route(tag).map(|route| (tag.to_owned(), route))
        });
        let detected_tag = configured
            .as_ref()
            .map(|(tag, _)| tag.clone())
            .or_else(|| confidence_values.first().map(|(language, _)| language_tag(*language).to_owned()));
        let route = configured.map(|(_, route)| route);
        let configured = route.is_some();
        let needs_review = !configured;
        sentences.push(Sentence {
            id: Uuid::new_v4(),
            text: sentence.into(),
            detected_language_tag: detected_tag.clone(),
            route: route.unwrap_or_else(|| settings.default_language_route()),
            needs_review,
            detected_but_unconfigured: detected_tag.is_some() && !configured,
        });
    }

    if sentences.is_empty() {
        single_sentence(text, settings)
    } else {
        Plan { sentences }
    }
}

pub fn supported_languages() -> &'static [(&'static str, &'static str)] {
    &[
        ("en-US", "English"),
        ("da-DK", "Danish"),
        ("sv-SE", "Swedish"),
        ("nb-NO", "Norwegian Bokmål"),
        ("de-DE", "German"),
        ("fr-FR", "French"),
        ("es-ES", "Spanish"),
        ("it-IT", "Italian"),
        ("nl-NL", "Dutch"),
        ("pt-PT", "Portuguese"),
    ]
}

fn detector() -> &'static LanguageDetector {
    static DETECTOR: OnceLock<LanguageDetector> = OnceLock::new();
    DETECTOR.get_or_init(|| {
        LanguageDetectorBuilder::from_languages(&[
            Language::English,
            Language::Danish,
            Language::Swedish,
            Language::Bokmal,
            Language::German,
            Language::French,
            Language::Spanish,
            Language::Italian,
            Language::Dutch,
            Language::Portuguese,
        ])
        .build()
    })
}

fn language_tag(language: Language) -> &'static str {
    match language {
        Language::English => "en-US",
        Language::Danish => "da-DK",
        Language::Swedish => "sv-SE",
        Language::Bokmal => "nb-NO",
        Language::German => "de-DE",
        Language::French => "fr-FR",
        Language::Spanish => "es-ES",
        Language::Italian => "it-IT",
        Language::Dutch => "nl-NL",
        Language::Portuguese => "pt-PT",
    }
}

fn shares_automatic_language_group(detected: Language, candidate: Language) -> bool {
    if detected == candidate {
        return true;
    }

    matches!(
        (detected, candidate),
        (Language::Danish | Language::Swedish | Language::Bokmal,
         Language::Danish | Language::Swedish | Language::Bokmal)
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::LanguageRoute;

    #[test]
    fn routes_each_configured_language() {
        let settings = Settings {
            default_language_tag: "en-US".into(),
            language_routes: vec![LanguageRoute::new("da-DK")],
            ..Settings::default()
        };

        let plan = plan(
            "This sentence is written in English. Denne sætning er skrevet på dansk.",
            &settings,
        );

        assert_eq!(plan.sentences.len(), 2);
        assert_eq!(plan.sentences[0].route.language_tag, "en-US");
        assert_eq!(plan.sentences[1].route.language_tag, "da-DK");
        assert!(!plan.needs_language_check());
    }

    #[test]
    fn prefers_a_configured_scandinavian_language_over_an_ambiguous_candidate() {
        let settings = Settings {
            default_language_tag: "en-US".into(),
            language_routes: vec![LanguageRoute::new("da-DK")],
            ..Settings::default()
        };

        let plan = plan("Det er en god dag", &settings);
        assert_eq!(plan.sentences[0].detected_language_tag.as_deref(), Some("da-DK"));
        assert_eq!(plan.sentences[0].route.language_tag, "da-DK");
        assert!(!plan.needs_language_check());
    }

    #[test]
    fn unrelated_configured_language_does_not_replace_detected_german() {
        let settings = Settings {
            default_language_tag: "en-US".into(),
            language_routes: vec![LanguageRoute::new("da-DK")],
            ..Settings::default()
        };

        let plan = plan("Ich heiße Jonas", &settings);
        assert_eq!(plan.sentences[0].detected_language_tag.as_deref(), Some("de-DE"));
        assert!(plan.needs_language_check());
    }

    #[test]
    fn unconfigured_language_requires_review() {
        let settings = Settings::default();
        let plan = plan("Denne sætning er skrevet på dansk.", &settings);

        assert!(plan.needs_language_check());
        assert!(plan.sentences[0].detected_but_unconfigured);
        assert_eq!(plan.sentences[0].route.language_tag, "en-US");
    }

    #[test]
    fn disabling_switching_uses_one_default_route() {
        let settings = Settings {
            language_switching_enabled: false,
            ..Settings::default()
        };
        let plan = plan("Hello. Goddag.", &settings);

        assert!(
            plan.sentences
                .iter()
                .all(|sentence| sentence.route.language_tag == "en-US" && !sentence.needs_review)
        );
    }

    #[test]
    fn override_forces_route_and_skips_review() {
        let settings = Settings {
            default_language_tag: "en-US".into(),
            language_routes: vec![LanguageRoute::new("da-DK")],
            ..Settings::default()
        };

        let plan = plan_with_override("Hello. Goddag.", &settings, Some("da-DK"));
        assert_eq!(plan.sentences.len(), 2);
        assert!(plan
            .sentences
            .iter()
            .all(|sentence| sentence.route.language_tag == "da-DK"
                && sentence.detected_language_tag.as_deref() == Some("da-DK")
                && !sentence.needs_review
                && !sentence.detected_but_unconfigured));

        let unrouted = plan_with_override("Hello.", &settings, Some("fr-FR"));
        assert_eq!(unrouted.sentences[0].route.language_tag, "en-US");
        assert!(!unrouted.needs_language_check());
    }

    #[test]
    fn without_review_clears_every_flag() {
        let settings = Settings::default();
        let plan = plan_with_override("Denne sætning er på dansk.", &settings, None)
            .without_review();

        assert!(!plan.needs_language_check());
        assert!(plan
            .sentences
            .iter()
            .all(|sentence| !sentence.detected_but_unconfigured));
    }
}
