use std::sync::OnceLock;

use lingua::{Language, LanguageDetector, LanguageDetectorBuilder};
use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

use crate::model::{LanguageRoute, Settings};

const UNCERTAIN_CONFIDENCE: f64 = 0.75;
const UNCERTAIN_LEAD: f64 = 0.15;

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
    let detector = detector();
    let mut sentences = Vec::new();

    for raw_sentence in text.split_sentence_bounds() {
        let sentence = raw_sentence.trim();
        if sentence.is_empty() {
            continue;
        }
        let confidence_values = detector.compute_language_confidence_values(sentence);
        let detected_tag = confidence_values
            .first()
            .map(|(language, _)| language_tag(*language).to_owned());
        let route = settings
            .language_switching_enabled
            .then(|| {
                detected_tag
                    .as_deref()
                    .and_then(|tag| settings.language_route(tag))
            })
            .flatten();
        let configured = route.is_some();
        let confidence = confidence_values.first().map_or(0.0, |(_, value)| *value);
        let second = confidence_values.get(1).map_or(0.0, |(_, value)| *value);
        let uncertain = confidence < UNCERTAIN_CONFIDENCE || confidence - second < UNCERTAIN_LEAD;
        let needs_review = settings.language_switching_enabled && (uncertain || !configured);
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
}
