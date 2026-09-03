use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub const MAXIMUM_SELECTION_CHARACTERS: usize = 45_000;
pub const FALLBACK_ROUTE_ID: Uuid = Uuid::from_u128(1);

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SpeechSource {
    #[default]
    System,
    Azure,
    Google,
    Piper,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SameSelectionAction {
    #[default]
    PauseResume,
    Restart,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum HotKeyPreset {
    #[default]
    AltSuperR,
    AltSuperSpace,
    ControlAltR,
    Custom,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct HotKey {
    pub key: String,
    pub control: bool,
    pub alt: bool,
    pub shift: bool,
    pub super_key: bool,
}

impl Default for HotKey {
    fn default() -> Self {
        Self {
            key: "R".into(),
            control: false,
            alt: true,
            shift: false,
            super_key: true,
        }
    }
}

impl HotKey {
    pub fn title(&self, super_name: &str) -> String {
        let mut parts = Vec::new();
        if self.control {
            parts.push("Ctrl");
        }
        if self.alt {
            parts.push("Alt");
        }
        if self.shift {
            parts.push("Shift");
        }
        if self.super_key {
            parts.push(super_name);
        }
        parts.push(&self.key);
        parts.join("+")
    }

    pub fn preferred_trigger(&self) -> String {
        let mut parts = Vec::new();
        if self.control {
            parts.push("CTRL".to_owned());
        }
        if self.alt {
            parts.push("ALT".to_owned());
        }
        if self.shift {
            parts.push("SHIFT".to_owned());
        }
        if self.super_key {
            parts.push("LOGO".to_owned());
        }
        parts.push(self.key.to_ascii_lowercase());
        parts.join("+")
    }
}

impl HotKeyPreset {
    pub const fn preferred_trigger(self) -> &'static str {
        match self {
            Self::AltSuperR => "ALT+LOGO+r",
            Self::AltSuperSpace => "ALT+LOGO+space",
            Self::ControlAltR => "CTRL+ALT+r",
            Self::Custom => "ALT+LOGO+r",
        }
    }

    pub const fn title(self) -> &'static str {
        match self {
            Self::AltSuperR => "Alt-Super-R",
            Self::AltSuperSpace => "Alt-Super-Space",
            Self::ControlAltR => "Control-Alt-R",
            Self::Custom => "Custom",
        }
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct LanguageRoute {
    pub id: Uuid,
    pub language_tag: String,
    pub system_voice_name: Option<String>,
    pub system_speech_rate: f64,
    pub azure_voice_name: Option<String>,
    pub azure_speech_rate: f64,
    pub google_voice_name: Option<String>,
    pub google_speech_rate: f64,
    pub piper_voice_name: Option<String>,
    pub playback_speed: Option<f64>,
}

impl LanguageRoute {
    pub fn effective_playback_speed(&self, global: f64) -> f64 {
        self.playback_speed.unwrap_or(global).clamp(0.5, 4.0)
    }
}

impl LanguageRoute {
    pub fn new(language_tag: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4(),
            language_tag: language_tag.into(),
            ..Self::default()
        }
    }
}

impl Default for LanguageRoute {
    fn default() -> Self {
        Self {
            id: Uuid::new_v4(),
            language_tag: "en-US".into(),
            system_voice_name: None,
            system_speech_rate: 0.0,
            azure_voice_name: None,
            azure_speech_rate: 0.0,
            google_voice_name: None,
            google_speech_rate: 0.0,
            piper_voice_name: None,
            playback_speed: None,
        }
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    pub speech_source: SpeechSource,
    pub hot_key: HotKeyPreset,
    pub custom_hot_key: HotKey,
    pub system_voice_name: Option<String>,
    pub system_speech_rate: f64,
    pub popup_dismiss_seconds: f64,
    pub same_selection_action: SameSelectionAction,
    pub word_highlighting_enabled: bool,
    pub azure_voice_name: String,
    pub azure_speech_rate: f64,
    pub google_voice_name: Option<String>,
    pub google_speech_rate: f64,
    pub google_api_key_configured: bool,
    pub piper_voice_name: Option<String>,
    pub playback_speed: f64,
    pub default_language_tag: String,
    pub language_routes: Vec<LanguageRoute>,
    pub azure_endpoint: Option<String>,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            speech_source: SpeechSource::System,
            hot_key: HotKeyPreset::AltSuperR,
            custom_hot_key: HotKey::default(),
            system_voice_name: None,
            system_speech_rate: 0.0,
            popup_dismiss_seconds: 8.0,
            same_selection_action: SameSelectionAction::PauseResume,
            word_highlighting_enabled: false,
            azure_voice_name: "en-US-AvaMultilingualNeural".into(),
            azure_speech_rate: 0.0,
            google_voice_name: None,
            google_speech_rate: 0.0,
            google_api_key_configured: false,
            piper_voice_name: None,
            playback_speed: 1.0,
            default_language_tag: "en-US".into(),
            language_routes: Vec::new(),
            azure_endpoint: None,
        }
    }
}

impl Settings {
    pub fn hot_key_binding(&self) -> HotKey {
        match self.hot_key {
            HotKeyPreset::AltSuperR => HotKey::default(),
            HotKeyPreset::AltSuperSpace => HotKey {
                key: "Space".into(),
                ..HotKey::default()
            },
            HotKeyPreset::ControlAltR => HotKey {
                control: true,
                super_key: false,
                ..HotKey::default()
            },
            HotKeyPreset::Custom => self.custom_hot_key.clone(),
        }
    }

    pub fn fallback_route(&self) -> LanguageRoute {
        LanguageRoute {
            id: FALLBACK_ROUTE_ID,
            language_tag: self.default_language_tag.clone(),
            system_voice_name: self.system_voice_name.clone(),
            system_speech_rate: self.system_speech_rate,
            azure_voice_name: Some(self.azure_voice_name.clone()),
            azure_speech_rate: self.azure_speech_rate,
            google_voice_name: self.google_voice_name.clone(),
            google_speech_rate: self.google_speech_rate,
            piper_voice_name: self.piper_voice_name.clone(),
            playback_speed: None,
        }
    }

    pub fn all_language_routes(&self) -> Vec<LanguageRoute> {
        std::iter::once(self.fallback_route())
            .chain(self.language_routes.iter().cloned())
            .collect()
    }

    pub fn language_route(&self, detected_tag: &str) -> Option<LanguageRoute> {
        let detected_base = language_base(detected_tag);
        self.language_routes
            .iter()
            .find(|route| {
                route.language_tag.eq_ignore_ascii_case(detected_tag)
                    || language_base(&route.language_tag) == detected_base
            })
            .cloned()
    }
}

pub fn language_base(tag: &str) -> String {
    tag.split('-').next().unwrap_or(tag).to_ascii_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn route_lookup_accepts_regional_variants() {
        let settings = Settings {
            default_language_tag: "en-US".into(),
            language_routes: vec![LanguageRoute::new("en-US"), LanguageRoute::new("da-DK")],
            ..Settings::default()
        };

        assert_eq!(settings.language_route("da").unwrap().language_tag, "da-DK");
        assert_eq!(
            settings.language_route("en-GB").unwrap().language_tag,
            "en-US"
        );
    }

    #[test]
    fn hot_key_binding_resolves_presets_and_custom() {
        let settings = Settings::default();
        assert_eq!(settings.hot_key_binding(), HotKey::default());

        let settings = Settings {
            hot_key: HotKeyPreset::AltSuperSpace,
            ..Settings::default()
        };
        assert_eq!(settings.hot_key_binding().key, "Space");

        let custom = HotKey {
            key: "F5".into(),
            control: true,
            alt: false,
            shift: true,
            super_key: false,
        };
        let settings = Settings {
            hot_key: HotKeyPreset::Custom,
            custom_hot_key: custom.clone(),
            ..Settings::default()
        };
        assert_eq!(settings.hot_key_binding(), custom);
    }

    #[test]
    fn hot_key_titles_and_triggers() {
        let hot_key = HotKey::default();
        assert_eq!(hot_key.title("Win"), "Alt+Win+R");
        assert_eq!(hot_key.title("Super"), "Alt+Super+R");
        assert_eq!(hot_key.preferred_trigger(), "ALT+LOGO+r");

        let hot_key = HotKey {
            key: "Space".into(),
            control: true,
            alt: false,
            shift: true,
            super_key: false,
        };
        assert_eq!(hot_key.title("Win"), "Ctrl+Shift+Space");
        assert_eq!(hot_key.preferred_trigger(), "CTRL+SHIFT+space");
    }
}
