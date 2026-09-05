//! Piper text-to-speech: a local, offline neural speech source. Flow shells
//! out to the `piper` executable (bundled in the AppImage or installed on
//! PATH) and downloads voice models on demand from the Hugging Face
//! rhasspy/piper-voices catalog.

use std::{
    io::Write,
    path::PathBuf,
    process::{Command, Stdio},
};

use serde::{Deserialize, Serialize};

use flow_core::{language, model::language_base};

const VOICES_CATALOG_URL: &str =
    "https://huggingface.co/rhasspy/piper-voices/resolve/main/voices.json";
const VOICE_DOWNLOAD_URL: &str = "https://huggingface.co/rhasspy/piper-voices/resolve/main/";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PiperVoice {
    pub key: String,
    pub name: String,
    pub language_code: String,
    pub quality: String,
    pub speakers: u32,
    pub installed: bool,
}

#[derive(Deserialize)]
struct RawCatalog {
    #[serde(flatten)]
    entries: std::collections::HashMap<String, RawVoice>,
}

#[derive(Deserialize)]
struct RawVoice {
    name: String,
    quality: String,
    language: RawLanguage,
    num_speakers: u32,
    files: std::collections::HashMap<String, serde::de::IgnoredAny>,
}

#[derive(Deserialize)]
struct RawLanguage {
    code: String,
}

/// Executable path of the Piper engine. Prefers a copy bundled next to Flow
/// (AppImage layout) and falls back to the search path so development builds
/// can use a distro-installed piper.
pub fn find_engine() -> Option<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(dir) = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|dir| dir.to_path_buf()))
    {
        candidates.push(dir.join("piper"));
        candidates.push(dir.join("bin").join("piper"));
    }
    if let Some(search_path) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&search_path) {
            candidates.push(dir.join("piper"));
        }
    }
    candidates.into_iter().find(|path| path.is_file())
}

fn voices_dir() -> Option<PathBuf> {
    directories::BaseDirs::new().map(|dirs| dirs.data_dir().join("flow").join("piper"))
}

pub fn is_installed(key: &str) -> bool {
    voices_dir().is_some_and(|dir| dir.join(format!("{key}.onnx")).is_file())
}

/// Catalog entries whose language family matches one of Flow's supported
/// languages, sorted for stable display.
pub fn supported_catalog(raw: &str) -> Result<Vec<PiperVoice>, String> {
    let parsed: RawCatalog = serde_json::from_str(raw)
        .map_err(|_| "Flow could not read the Piper voice catalog.".to_owned())?;
    let mut voices: Vec<PiperVoice> = parsed
        .entries
        .into_iter()
        .map(|(key, entry)| PiperVoice {
            installed: is_installed(&key),
            key,
            name: entry.name,
            language_code: entry.language.code,
            quality: entry.quality,
            speakers: entry.num_speakers,
        })
        .filter(|voice| {
            let family = voice
                .language_code
                .split('_')
                .next()
                .unwrap_or_default()
                .to_ascii_lowercase();
            language::supported_languages()
                .iter()
                .any(|(tag, _)| language_base(tag) == family)
        })
        .collect();
    voices.sort_by(|left, right| {
        left.language_code
            .cmp(&right.language_code)
            .then(left.name.cmp(&right.name))
            .then(left.quality.cmp(&right.quality))
    });
    Ok(voices)
}

pub fn fetch_catalog() -> Result<Vec<PiperVoice>, String> {
    let raw = reqwest::blocking::Client::new()
        .get(VOICES_CATALOG_URL)
        .header(
            reqwest::header::USER_AGENT,
            concat!("flow-desktop/", env!("CARGO_PKG_VERSION")),
        )
        .send()
        .map_err(|_| "Flow could not reach huggingface.co to load Piper voices.".to_owned())?
        .error_for_status()
        .map_err(|_| "huggingface.co reported an error while loading Piper voices.".to_owned())?
        .text()
        .map_err(|_| "Flow could not read the Piper voice catalog.".to_owned())?;
    supported_catalog(&raw)
}

fn repo_path(entry: &RawVoice, suffix: &str) -> Option<String> {
    entry
        .files
        .keys()
        .find_map(|path| path.ends_with(suffix).then(|| path.to_owned()))
}

/// Downloads both the ONNX model and its config into Flow's data directory.
/// Each file lands via a temp rename so an interrupted download never leaves
/// a partial model that looks installed.
pub fn download_voice(key: &str) -> Result<(), String> {
    let dir = voices_dir()
        .ok_or_else(|| "Flow has no data directory available for Piper voices.".to_owned())?;
    std::fs::create_dir_all(&dir)
        .map_err(|_| "Flow could not create its Piper voice directory.".to_owned())?;

    let raw = fetch_raw_entry(key)?;
    for (suffix, message) in [(".onnx.json", "config"), (".onnx", "model")] {
        let path = repo_path(&raw, &format!("{key}{suffix}"))
            .ok_or_else(|| format!("The {key} voice has no {message} file in the catalog."))?;
        let bytes = reqwest::blocking::Client::new()
            .get(format!("{VOICE_DOWNLOAD_URL}{path}"))
            .header(
                reqwest::header::USER_AGENT,
                concat!("flow-desktop/", env!("CARGO_PKG_VERSION")),
            )
            .send()
            .and_then(|response| response.error_for_status())
            .map_err(|_| format!("Flow could not download the {key} voice {message}."))?
            .bytes()
            .map_err(|_| format!("Flow could not download the {key} voice {message}."))?;
        let target = dir.join(format!("{key}{suffix}"));
        let temp = dir.join(format!("{key}{suffix}.part"));
        std::fs::write(&temp, &bytes)
            .and_then(|()| std::fs::rename(&temp, &target))
            .map_err(|_| format!("Flow could not save the {key} voice {message}."))?;
    }
    Ok(())
}

pub fn delete_voice(key: &str) -> Result<(), String> {
    let Some(dir) = voices_dir() else {
        return Ok(());
    };
    for suffix in [".onnx", ".onnx.json"] {
        match std::fs::remove_file(dir.join(format!("{key}{suffix}"))) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => {
                return Err(format!("Flow could not remove the {key} voice."));
            }
        }
    }
    Ok(())
}

fn fetch_raw_entry(key: &str) -> Result<RawVoice, String> {
    let raw = reqwest::blocking::Client::new()
        .get(VOICES_CATALOG_URL)
        .header(
            reqwest::header::USER_AGENT,
            concat!("flow-desktop/", env!("CARGO_PKG_VERSION")),
        )
        .send()
        .map_err(|_| "Flow could not reach huggingface.co to find this voice.".to_owned())?
        .error_for_status()
        .map_err(|_| "huggingface.co reported an error while finding this voice.".to_owned())?
        .text()
        .map_err(|_| "Flow could not read the Piper voice catalog.".to_owned())?;
    let mut catalog: RawCatalog = serde_json::from_str(&raw)
        .map_err(|_| "Flow could not read the Piper voice catalog.".to_owned())?;
    catalog
        .entries
        .remove(key)
        .ok_or_else(|| format!("The {key} voice is no longer in the Piper catalog."))
}

/// Synthesizes one sentence to WAV bytes through the piper executable.
pub fn synthesize(
    engine: &std::path::Path,
    voice_key: &str,
    text: &str,
) -> Result<Vec<u8>, String> {
    let Some(dir) = voices_dir() else {
        return Err("Flow has no data directory available for Piper voices.".to_owned());
    };
    let model = dir.join(format!("{voice_key}.onnx"));
    let mut child = Command::new(engine)
        .arg("--model")
        .arg(&model)
        // "-" streams WAV to stdout in both the bundled legacy piper and
        // the newer piper1-gpl CLI; omitting it would try to play audio.
        .arg("--output_file")
        .arg("-")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| {
            "Flow could not start the Piper speech engine. Check that it is installed.".to_owned()
        })?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(text.as_bytes())
            .map_err(|_| "Flow could not send the selection to Piper.".to_owned())?;
    }
    let output = child
        .wait_with_output()
        .map_err(|_| "Flow lost contact with the Piper speech engine.".to_owned())?;
    if !output.status.success() || output.stdout.is_empty() {
        return Err(format!(
            "Piper could not synthesize this sentence with the {voice_key} voice."
        ));
    }
    Ok(output.stdout)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_filters_to_supported_languages() {
        let raw = r#"{
            "en_US-lessac-medium": {
                "key": "en_US-lessac-medium", "name": "lessac",
                "quality": "medium", "num_speakers": 1,
                "language": {"code": "en_US"},
                "files": {"en/en_US/lessac/medium/en_US-lessac-medium.onnx": {"size_bytes": 1}}
            },
            "ar_JO-kareem-low": {
                "key": "ar_JO-kareem-low", "name": "kareem",
                "quality": "low", "num_speakers": 1,
                "language": {"code": "ar_JO"},
                "files": {}
            },
            "da_DK-talesyntese-medium": {
                "key": "da_DK-talesyntese-medium", "name": "talesyntese",
                "quality": "medium", "num_speakers": 1,
                "language": {"code": "da_DK"},
                "files": {}
            }
        }"#;
        let voices = supported_catalog(raw).expect("catalog parses");
        let keys: Vec<&str> = voices.iter().map(|voice| voice.key.as_str()).collect();
        assert_eq!(keys, ["da_DK-talesyntese-medium", "en_US-lessac-medium"]);
    }

    #[test]
    fn synthesize_streams_wav_from_the_engine() {
        let Some(engine) = find_engine() else {
            eprintln!("skipping: no piper engine on PATH");
            return;
        };
        let key = std::env::var("FLOW_TEST_PIPER_VOICE")
            .unwrap_or_else(|_| "en_US-lessac-medium".to_owned());
        if !is_installed(&key) {
            eprintln!("skipping: {key} is not downloaded");
            return;
        }
        let wav =
            synthesize(&engine, &key, "Flow reads selected text.").expect("piper synthesizes");
        assert!(wav.starts_with(b"RIFF"), "expected WAV bytes from piper");
    }
}
