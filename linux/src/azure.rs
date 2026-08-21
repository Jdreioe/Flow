use keyring::Entry;
use reqwest::{Url, blocking::Client};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use flow_core::{
    language::Plan,
    model::Settings,
};

const KEYRING_SERVICE: &str = "io.github.jdreioe.flow.azure-speech";
const KEYRING_ACCOUNT: &str = "byok";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AzureVoice {
    #[serde(rename = "ShortName")]
    pub short_name: String,
    #[serde(rename = "Locale")]
    pub locale: String,
    #[serde(rename = "SecondaryLocaleList", default)]
    pub secondary_locales: Vec<String>,
}

#[derive(Debug, Error, PartialEq)]
pub enum AzureError {
    #[error("Enter an Azure Speech region or HTTPS endpoint.")]
    InvalidEndpoint,
    #[error("Enter a valid Azure Speech subscription key.")]
    InvalidKey,
    #[error("Enter a valid Azure neural voice name.")]
    InvalidVoice,
    #[error("Flow could not access the Azure credential in your desktop keyring.")]
    Keyring,
    #[error("Azure Speech returned an unsuccessful response.")]
    Request,
}

pub fn normalize_endpoint(raw: &str) -> Result<String, AzureError> {
    let value = raw.trim().to_ascii_lowercase();
    if value.is_empty() || value.chars().any(char::is_whitespace) {
        return Err(AzureError::InvalidEndpoint);
    }
    if !value.contains('.') && !value.contains("://") {
        if value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || character == '-')
        {
            return Ok(format!("https://{value}.tts.speech.microsoft.com"));
        }
        return Err(AzureError::InvalidEndpoint);
    }

    let candidate = if value.contains("://") {
        value
    } else {
        format!("https://{value}")
    };
    let url = Url::parse(&candidate).map_err(|_| AzureError::InvalidEndpoint)?;
    if url.scheme() != "https"
        || url.username() != ""
        || url.password().is_some()
        || url.port().is_some_and(|port| port != 443)
        || !matches!(url.path(), "" | "/")
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(AzureError::InvalidEndpoint);
    }
    let host = url.host_str().ok_or(AzureError::InvalidEndpoint)?;
    let supported = host.ends_with(".tts.speech.microsoft.com")
        || host.ends_with(".tts.speech.azure.com")
        || host.ends_with(".cognitiveservices.azure.com");
    if !supported || host.split('.').count() < 4 {
        return Err(AzureError::InvalidEndpoint);
    }
    Ok(format!("https://{host}"))
}

pub fn validate_key(raw: &str) -> Result<String, AzureError> {
    let key = raw.trim();
    if key.is_empty() || key.chars().any(char::is_whitespace) {
        Err(AzureError::InvalidKey)
    } else {
        Ok(key.to_owned())
    }
}

pub fn save_key(key: &str) -> Result<(), AzureError> {
    Entry::new(KEYRING_SERVICE, KEYRING_ACCOUNT)
        .and_then(|entry| entry.set_password(key))
        .map_err(|_| AzureError::Keyring)
}

pub fn load_key() -> Result<String, AzureError> {
    Entry::new(KEYRING_SERVICE, KEYRING_ACCOUNT)
        .and_then(|entry| entry.get_password())
        .map_err(|_| AzureError::Keyring)
}

pub fn clear_key() {
    if let Ok(entry) = Entry::new(KEYRING_SERVICE, KEYRING_ACCOUNT) {
        let _ = entry.delete_credential();
    }
}

pub fn list_voices(endpoint: &str, key: &str) -> Result<Vec<AzureVoice>, AzureError> {
    let suffix = if endpoint.contains(".cognitiveservices.azure.com") {
        "/tts/cognitiveservices/voices/list"
    } else {
        "/cognitiveservices/voices/list"
    };
    let mut voices = client()
        .get(format!("{endpoint}{suffix}"))
        .header("Ocp-Apim-Subscription-Key", key)
        .header("User-Agent", "Flow")
        .send()
        .map_err(|_| AzureError::Request)?
        .error_for_status()
        .map_err(|_| AzureError::Request)?
        .json::<Vec<AzureVoice>>()
        .map_err(|_| AzureError::Request)?;
    voices.sort_by_key(|voice| voice.short_name.to_ascii_lowercase());
    Ok(voices)
}

pub fn synthesize(
    endpoint: &str,
    key: &str,
    plan: &Plan,
    settings: &Settings,
) -> Result<Vec<u8>, AzureError> {
    let ssml = ssml(plan, settings)?;
    let bytes = client()
        .post(format!("{endpoint}/cognitiveservices/v1"))
        .header("Ocp-Apim-Subscription-Key", key)
        .header("Content-Type", "application/ssml+xml")
        .header(
            "X-Microsoft-OutputFormat",
            "audio-24khz-160kbitrate-mono-mp3",
        )
        .header("User-Agent", "Flow")
        .body(ssml)
        .send()
        .map_err(|_| AzureError::Request)?
        .error_for_status()
        .map_err(|_| AzureError::Request)?
        .bytes()
        .map_err(|_| AzureError::Request)?;
    if bytes.is_empty() {
        Err(AzureError::Request)
    } else {
        Ok(bytes.to_vec())
    }
}

fn ssml(plan: &Plan, settings: &Settings) -> Result<String, AzureError> {
    let mut body = String::new();
    for sentence in &plan.sentences {
        let raw_voice = sentence
            .route
            .azure_voice_name
            .as_ref()
            .unwrap_or(&settings.azure_voice_name);
        let voice = raw_voice.trim();
        if voice.is_empty()
            || !voice
                .chars()
                .all(|character| character.is_ascii_alphanumeric() || character == '-')
        {
            return Err(AzureError::InvalidVoice);
        }
        let rate = sentence.route.azure_speech_rate;
        body.push_str(&format!(
            "<voice name=\"{}\"><lang xml:lang=\"{}\"><prosody rate=\"{}%\">{}</prosody></lang></voice>",
            voice,
            escape_xml(&sentence.route.language_tag),
            azure_rate(rate),
            escape_xml(&sentence.text),
        ));
    }
    Ok(format!(
        "<speak version=\"1.0\" xml:lang=\"{}\">{body}</speak>",
        escape_xml(&settings.default_language_tag)
    ))
}

fn azure_rate(rate: f64) -> i32 {
    (rate.clamp(-1.0, 1.0) * 50.0).round() as i32
}

fn escape_xml(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

fn client() -> Client {
    Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .expect("the static HTTP client configuration is valid")
}

#[cfg(test)]
mod tests {
    use super::*;
    use flow_core::language;

    #[test]
    fn normalizes_region_and_rejects_non_azure_hosts() {
        assert_eq!(
            normalize_endpoint("WestEurope").unwrap(),
            "https://westeurope.tts.speech.microsoft.com"
        );
        assert_eq!(
            normalize_endpoint("https://example.com"),
            Err(AzureError::InvalidEndpoint)
        );
        assert_eq!(
            normalize_endpoint("http://westeurope.tts.speech.microsoft.com"),
            Err(AzureError::InvalidEndpoint)
        );
    }

    #[test]
    fn ssml_escapes_selection_and_uses_route_language() {
        let settings = Settings::default();
        let plan = language::single_sentence("Fish & chips <3", &settings);
        let result = ssml(&plan, &settings).unwrap();

        assert!(result.contains("xml:lang=\"en-US\""));
        assert!(result.contains("Fish &amp; chips &lt;3"));
        assert!(!result.contains("Fish & chips"));
    }
}
