use base64::{Engine as _, engine::general_purpose::STANDARD};
use keyring::Entry;
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use flow_core::language::Plan;

const API_ROOT: &str = "https://texttospeech.googleapis.com/v1";
const KEYRING_SERVICE: &str = "io.github.jdreioe.flow.google-cloud-tts";
const KEYRING_ACCOUNT: &str = "byok";
// Google limits synchronous text input to 5,000 bytes. Leave room for future
// request additions while keeping every Unicode chunk below that boundary.
const MAX_INPUT_BYTES: usize = 4_500;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GoogleVoice {
    pub language_codes: Vec<String>,
    pub name: String,
    pub ssml_gender: String,
}

#[derive(Debug, Error, PartialEq)]
pub enum GoogleError {
    #[error("Enter a valid Google Cloud API key.")]
    InvalidKey,
    #[error("Flow could not access the Google Cloud credential in your desktop keyring.")]
    Keyring,
    #[error("Google Cloud Text-to-Speech returned an unsuccessful response.")]
    Request,
}

#[derive(Deserialize)]
struct VoicesResponse {
    voices: Vec<GoogleVoice>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SynthesisRequest<'a> {
    input: SynthesisInput<'a>,
    voice: VoiceSelection<'a>,
    audio_config: AudioConfig,
}

#[derive(Serialize)]
struct SynthesisInput<'a> {
    text: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct VoiceSelection<'a> {
    language_code: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<&'a str>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AudioConfig {
    audio_encoding: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    speaking_rate: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SynthesisResponse {
    audio_content: String,
}

pub fn validate_key(raw: &str) -> Result<String, GoogleError> {
    let key = raw.trim();
    if key.is_empty() || key.chars().any(char::is_whitespace) {
        Err(GoogleError::InvalidKey)
    } else {
        Ok(key.to_owned())
    }
}

pub fn save_key(key: &str) -> Result<(), GoogleError> {
    Entry::new(KEYRING_SERVICE, KEYRING_ACCOUNT)
        .and_then(|entry| entry.set_password(key))
        .map_err(|_| GoogleError::Keyring)
}

pub fn load_key() -> Result<String, GoogleError> {
    Entry::new(KEYRING_SERVICE, KEYRING_ACCOUNT)
        .and_then(|entry| entry.get_password())
        .map_err(|_| GoogleError::Keyring)
}

pub fn clear_key() {
    if let Ok(entry) = Entry::new(KEYRING_SERVICE, KEYRING_ACCOUNT) {
        let _ = entry.delete_credential();
    }
}

pub fn list_voices(key: &str) -> Result<Vec<GoogleVoice>, GoogleError> {
    let mut voices = client()
        .get(format!("{API_ROOT}/voices"))
        .header("x-goog-api-key", key)
        .header("User-Agent", "Flow")
        .send()
        .map_err(|_| GoogleError::Request)?
        .error_for_status()
        .map_err(|_| GoogleError::Request)?
        .json::<VoicesResponse>()
        .map_err(|_| GoogleError::Request)?
        .voices;
    voices.sort_by_key(|voice| voice.name.to_ascii_lowercase());
    Ok(voices)
}

pub fn synthesize(key: &str, plan: &Plan) -> Result<Vec<Vec<u8>>, GoogleError> {
    let client = client();
    let mut audio_segments = Vec::new();
    for sentence in &plan.sentences {
        let voice_name = sentence
            .route
            .google_voice_name
            .as_deref()
            .map(str::trim)
            .filter(|name| !name.is_empty());
        for chunk in text_chunks(&sentence.text) {
            let request = SynthesisRequest {
                input: SynthesisInput { text: chunk },
                voice: VoiceSelection {
                    language_code: &sentence.route.language_tag,
                    name: voice_name,
                },
                audio_config: AudioConfig {
                    audio_encoding: "MP3",
                    speaking_rate: (sentence.route.google_speech_rate.abs() > f64::EPSILON)
                        .then(|| google_rate(sentence.route.google_speech_rate)),
                },
            };
            let response = client
                .post(format!("{API_ROOT}/text:synthesize"))
                .header("x-goog-api-key", key)
                .header("User-Agent", "Flow")
                .json(&request)
                .send()
                .map_err(|_| GoogleError::Request)?
                .error_for_status()
                .map_err(|_| GoogleError::Request)?
                .json::<SynthesisResponse>()
                .map_err(|_| GoogleError::Request)?;
            let audio = STANDARD
                .decode(response.audio_content)
                .map_err(|_| GoogleError::Request)?;
            if audio.is_empty() {
                return Err(GoogleError::Request);
            }
            audio_segments.push(audio);
        }
    }
    if audio_segments.is_empty() {
        Err(GoogleError::Request)
    } else {
        Ok(audio_segments)
    }
}

fn google_rate(rate: f64) -> f64 {
    1.0 + rate.clamp(-1.0, 1.0) * 0.5
}

fn text_chunks(text: &str) -> Vec<&str> {
    let mut remaining = text.trim();
    let mut chunks = Vec::new();
    while remaining.len() > MAX_INPUT_BYTES {
        let mut end = MAX_INPUT_BYTES;
        while !remaining.is_char_boundary(end) {
            end -= 1;
        }
        let split = remaining[..end]
            .char_indices()
            .rev()
            .find_map(|(index, character)| {
                (index > 0 && character.is_whitespace()).then_some(index)
            })
            .unwrap_or(end);
        chunks.push(remaining[..split].trim_end());
        remaining = remaining[split..].trim_start();
    }
    if !remaining.is_empty() {
        chunks.push(remaining);
    }
    chunks
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

    #[test]
    fn chunks_long_unicode_text_without_exceeding_google_limit() {
        let text = "æøå ".repeat(2_000);
        let chunks = text_chunks(&text);

        assert!(chunks.len() > 1);
        assert!(chunks.iter().all(|chunk| chunk.len() <= MAX_INPUT_BYTES));
        assert_eq!(chunks.join(" "), text.trim());
    }

    #[test]
    fn maps_flow_rate_to_google_speaking_rate() {
        assert_eq!(google_rate(-1.0), 0.5);
        assert_eq!(google_rate(0.0), 1.0);
        assert_eq!(google_rate(1.0), 1.5);
    }
}
