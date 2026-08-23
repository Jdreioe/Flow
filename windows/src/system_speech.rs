use std::{
    collections::VecDeque,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, RecvTimeoutError, Sender},
    },
    time::Duration,
};

use serde::Serialize;
use windows::{
    Foundation::TypedEventHandler,
    Media::{
        Core::MediaSource,
        Playback::{MediaPlaybackState, MediaPlayer},
        SpeechSynthesis::{SpeechSynthesisStream, SpeechSynthesizer, VoiceInformation},
    },
    Win32::System::Com::{COINIT_MULTITHREADED, CoInitializeEx},
    core::HSTRING,
};

use flow_core::{
    language::{Plan, Sentence},
    model::language_base,
};

const WAIT_SLICE: Duration = Duration::from_millis(50);
const RATE_RANGE: f64 = 0.5;

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SystemVoice {
    pub name: String,
    pub language_tag: String,
}

pub enum Command {
    Play { generation: u64, plan: Plan },
    Pause,
    Resume,
    Stop,
    Shutdown,
}

pub struct Callbacks {
    pub voices_changed: Box<dyn Fn(Vec<SystemVoice>) + Send>,
    pub finished: Box<dyn Fn(u64) + Send>,
    pub failed: Box<dyn Fn((u64, String)) + Send>,
}

struct VoiceEntry {
    info: SystemVoice,
    native: VoiceInformation,
}

struct Playback {
    generation: u64,
    sentences: VecDeque<Sentence>,
}

pub fn start(callbacks: Callbacks) -> Sender<Command> {
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || run(receiver, callbacks));
    sender
}

fn run(receiver: Receiver<Command>, callbacks: Callbacks) {
    let engine = match Engine::new() {
        Ok(engine) => engine,
        Err(error) => {
            run_unavailable(receiver, callbacks, error);
            return;
        }
    };
    (callbacks.voices_changed)(visible_voices(&engine.voices));

    let mut playback: Option<Playback> = None;
    let mut segment_generation: Option<u64> = None;
    loop {
        match receiver.recv_timeout(WAIT_SLICE) {
            Ok(command) => match command {
                Command::Play { generation, plan } => {
                    playback = Some(Playback {
                        generation,
                        sentences: plan.sentences.into(),
                    });
                    segment_generation = speak_next(&engine, &mut playback, &callbacks);
                }
                Command::Pause => {
                    let _ = engine.player.Pause();
                }
                Command::Resume => {
                    let _ = engine.player.Play();
                }
                Command::Stop => {
                    engine.stop();
                    segment_generation = None;
                    playback = None;
                }
                Command::Shutdown => return,
            },
            Err(RecvTimeoutError::Disconnected) => return,
            Err(RecvTimeoutError::Timeout) => {}
        }

        if let Some(generation) = segment_generation
            && engine.segment_ended()
        {
            if playback.as_ref().is_some_and(|item| item.generation == generation) {
                segment_generation = speak_next(&engine, &mut playback, &callbacks);
            } else {
                segment_generation = None;
            }
        }
    }
}

/// Speaks the next queued sentence. Returns the generation of a started
/// segment, or None when the queue drained or failed.
fn speak_next(
    engine: &Engine,
    playback: &mut Option<Playback>,
    callbacks: &Callbacks,
) -> Option<u64> {
    let Some(active) = playback else {
        return None;
    };
    let Some(sentence) = active.sentences.pop_front() else {
        let generation = active.generation;
        *playback = None;
        (callbacks.finished)(generation);
        return None;
    };

    match engine.speak(&sentence) {
        Ok(()) => Some(active.generation),
        Err(error) => {
            let generation = active.generation;
            *playback = None;
            (callbacks.failed)((generation, format!("Windows speech error: {error}")));
            None
        }
    }
}

fn run_unavailable(receiver: Receiver<Command>, callbacks: Callbacks, error: String) {
    (callbacks.voices_changed)(Vec::new());
    while let Ok(command) = receiver.recv() {
        match command {
            Command::Play { generation, .. } => (callbacks.failed)((generation, error.clone())),
            Command::Shutdown => break,
            _ => {}
        }
    }
}

struct Engine {
    synthesizer: SpeechSynthesizer,
    player: MediaPlayer,
    voices: Vec<VoiceEntry>,
    ended: Arc<AtomicBool>,
}

impl Engine {
    fn new() -> Result<Self, String> {
        unsafe { let _ = CoInitializeEx(None, COINIT_MULTITHREADED); };
        let synthesizer = SpeechSynthesizer::new().map_err(speech_error)?;
        let player = MediaPlayer::new().map_err(speech_error)?;
        let ended = Arc::new(AtomicBool::new(false));
        let signal = Arc::clone(&ended);
        player
            .MediaEnded(&TypedEventHandler::new(move |_, _| {
                signal.store(true, Ordering::SeqCst);
                Ok(())
            }))
            .map_err(speech_error)?;

        let view = SpeechSynthesizer::AllVoices().map_err(speech_error)?;
        let count = view.Size().map_err(speech_error)?;
        let mut voices = Vec::with_capacity(count as usize);
        for index in 0..count {
            let native: VoiceInformation = view.GetAt(index).map_err(speech_error)?;
            let name = native
                .DisplayName()
                .map_err(speech_error)?
                .to_string();
            let language_tag = native
                .Language()
                .map_err(speech_error)?
                .to_string();
            voices.push(VoiceEntry {
                info: SystemVoice { name, language_tag },
                native,
            });
        }

        Ok(Self {
            synthesizer,
            player,
            voices,
            ended,
        })
    }

    fn speak(&self, sentence: &Sentence) -> Result<(), String> {
        self.configure(sentence)?;
        let operation = self
            .synthesizer
            .SynthesizeTextToStreamAsync(&HSTRING::from(sentence.text.as_str()))
            .map_err(speech_error)?;
        let stream: SpeechSynthesisStream = operation.join().map_err(speech_error)?;
        let source =
            MediaSource::CreateFromStream(&stream, &HSTRING::from("audio/wav"))
                .map_err(speech_error)?;
        self.ended.store(false, Ordering::SeqCst);
        self.player.SetSource(&source).map_err(speech_error)?;
        self.player.Play().map_err(speech_error)
    }

    fn configure(&self, sentence: &Sentence) -> Result<(), String> {
        self.synthesizer
            .Options()
            .and_then(|options| options.SetSpeakingRate(windows_rate(sentence.route.system_speech_rate)))
            .map_err(speech_error)?;
        let requested = sentence.route.language_tag.replace('_', "-");
        let selected = sentence
            .route
            .system_voice_name
            .as_deref()
            .and_then(|name| self.voices.iter().find(|voice| voice.info.name == name));
        let default = self
            .voices
            .iter()
            .find(|voice| tags_match(&voice.info.language_tag, &requested))
            .or_else(|| {
                self.voices.iter().find(|voice| {
                    language_base(&voice.info.language_tag) == language_base(&requested)
                })
            });
        if let Some(voice) = selected.or(default) {
            self.synthesizer
                .SetVoice(&voice.native)
                .map_err(speech_error)?;
        }
        Ok(())
    }

    fn stop(&self) {
        let _ = self.player.Pause();
    }

    fn segment_ended(&self) -> bool {
        self.ended.load(Ordering::SeqCst)
            || !self
                .player
                .PlaybackSession()
                .and_then(|session| session.PlaybackState())
                .is_ok_and(|state| state == MediaPlaybackState::Playing || state == MediaPlaybackState::Paused)
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Flow rates span -1..1 like the other engines; Windows spans 0..3 where 1 is
/// normal, so keep the same Â±50 % convention used by Azure and Google.
fn windows_rate(rate: f64) -> f64 {
    1.0 + rate.clamp(-1.0, 1.0) * RATE_RANGE
}

fn visible_voices(voices: &[VoiceEntry]) -> Vec<SystemVoice> {
    let mut result = voices
        .iter()
        .filter(|voice| {
            flow_core::language::supported_languages()
                .iter()
                .any(|(tag, _)| language_base(&voice.info.language_tag) == language_base(tag))
        })
        .map(|voice| voice.info.clone())
        .collect::<Vec<_>>();
    result.sort_by(|left, right| {
        left.language_tag
            .cmp(&right.language_tag)
            .then_with(|| left.name.cmp(&right.name))
    });
    result.dedup();
    result
}

fn tags_match(left: &str, right: &str) -> bool {
    left.replace('_', "-").eq_ignore_ascii_case(right)
}

fn speech_error<E: std::fmt::Display>(error: E) -> String {
    error.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn language_tags_accept_underscore_or_dash() {
        assert!(tags_match("en-US", "en-US"));
        assert!(!tags_match("en-GB", "en-US"));
    }

    #[test]
    fn flow_rate_maps_inside_windows_range() {
        assert_eq!(windows_rate(-1.0), 0.5);
        assert_eq!(windows_rate(0.0), 1.0);
        assert_eq!(windows_rate(1.0), 1.5);
    }
}
