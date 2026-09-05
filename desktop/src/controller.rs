//! Playback and settings state machine shared by Linux and Windows.
//!
//! This is the Qt-free port of the two `FlowBackend` QObjects: the same
//! selection handling, language planning, synthesis fan-out, and settings
//! logic, with `queued_callback` replaced by worker threads posting
//! [`Event`]s back to the iced UI.

use std::{
    collections::VecDeque,
    io::Write,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};

use tempfile::TempPath;
use tokio::sync::mpsc::UnboundedSender;
use uuid::Uuid;

use flow_core::{
    language::{self, Plan},
    model::{
        AzureVoiceMode, DEFAULT_LANGUAGE_ROUTE_ID, HotKeyPreset, LanguageRoute,
        MAXIMUM_SELECTION_CHARACTERS, SameSelectionAction, Settings, SpeechSource, language_base,
    },
};

use crate::{
    Message,
    audio::Player,
    azure::{self, AzureVoice},
    google::{self, GoogleVoice},
    piper::{self, PiperVoice},
    selection, settings, shortcuts,
    system_speech::{self, SystemVoice},
    updates,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PlaybackState {
    Hidden,
    Preparing,
    Playing,
    Paused,
    AwaitingRoute,
    Finished,
    Message,
}

impl PlaybackState {
    /// Popup title, matching the macOS presentation.
    pub const fn title(self) -> &'static str {
        match self {
            Self::Hidden => "Flow",
            Self::Preparing => "Preparing playback",
            Self::Playing => "Reading",
            Self::Paused => "Paused",
            Self::AwaitingRoute => "Choose a voice",
            Self::Finished => "Finished",
            Self::Message => "Flow",
        }
    }
}

/// One synthesized cloud/Piper segment ready for local playback.
#[derive(Clone, Debug)]
pub struct CloudSegment {
    pub bytes: Vec<u8>,
    pub extension: &'static str,
    pub word_timings: Vec<google::WordTiming>,
    pub playback_speed: Option<f64>,
}

/// Worker-thread completions delivered to the iced UI.
#[derive(Clone, Debug)]
pub enum Event {
    SelectionDone {
        request_id: u64,
        result: Result<String, String>,
    },
    ShortcutActivated,
    ShortcutStatus(String),
    SystemVoices(Vec<SystemVoice>),
    SpeechFinished(u64),
    SpeechFailed {
        generation: u64,
        message: String,
    },
    SpeechWordRange {
        generation: u64,
        start: u32,
        end: u32,
    },
    AzureVoices(Result<Vec<AzureVoice>, String>),
    GoogleVoices(Result<Vec<GoogleVoice>, String>),
    PiperCatalog(Result<Vec<PiperVoice>, String>),
    PiperDownloaded {
        key: String,
        result: Result<(), String>,
    },
    PiperPreview {
        generation: u64,
        result: Result<Vec<u8>, String>,
    },
    PiperDeleted(Result<(), String>),
    CloudSynthesized {
        generation: u64,
        result: Result<Vec<CloudSegment>, String>,
    },
    CloudSegmentDone,
    WordTick {
        generation: u64,
        start: i32,
        end: i32,
    },
    AutoDismiss(u64),
    UpdateResult {
        manual: bool,
        result: Result<String, String>,
    },
}

pub struct Controller {
    tx: UnboundedSender<Message>,
    pub settings: Settings,
    pub playback_state: PlaybackState,
    pub selected_text: String,
    pub playback_text: String,
    pub message: String,
    pub plan: Option<Plan>,
    pub language_override: Option<String>,
    pub detected_languages: Vec<String>,
    pub manual_route_needed: bool,
    pub manual_route_sentence_text: String,
    pub override_needs_route: bool,
    pub system_voices: Vec<SystemVoice>,
    pub azure_voices: Vec<AzureVoice>,
    pub google_voices: Vec<GoogleVoice>,
    pub piper_voices: Vec<PiperVoice>,
    pub shortcut_status: String,
    pub configuration_error: String,
    pub piper_status: String,
    pub update_ready_version: String,
    pub playback_speed: f64,
    pub current_word_start: i32,
    pub current_word_end: i32,
    audio_path: Option<TempPath>,
    queued_audio_paths: VecDeque<TempPath>,
    queued_word_timings: VecDeque<Vec<google::WordTiming>>,
    queued_segment_speeds: VecDeque<Option<f64>>,
    preview_path: Option<TempPath>,
    preview_generation: u64,
    piper_downloading: Option<String>,
    shortcut_commands: Option<UnboundedSender<shortcuts::Command>>,
    system_speech_commands: Option<std::sync::mpsc::Sender<system_speech::Command>>,
    services_started: bool,
    selection_generation: Arc<AtomicU64>,
    dismiss_generation: Arc<AtomicU64>,
    playback_generation: Arc<AtomicU64>,
}

impl Controller {
    pub fn new(tx: UnboundedSender<Message>) -> Self {
        let settings = settings::load();
        let playback_speed = settings.playback_speed;
        Self {
            tx,
            settings,
            playback_state: PlaybackState::Hidden,
            selected_text: String::new(),
            playback_text: String::new(),
            message: String::new(),
            plan: None,
            language_override: None,
            detected_languages: Vec::new(),
            manual_route_needed: false,
            manual_route_sentence_text: String::new(),
            override_needs_route: false,
            system_voices: Vec::new(),
            azure_voices: Vec::new(),
            google_voices: Vec::new(),
            piper_voices: Vec::new(),
            shortcut_status: "Registering global shortcut…".into(),
            configuration_error: String::new(),
            piper_status: String::new(),
            update_ready_version: String::new(),
            playback_speed,
            current_word_start: -1,
            current_word_end: -1,
            audio_path: None,
            queued_audio_paths: VecDeque::new(),
            queued_word_timings: VecDeque::new(),
            queued_segment_speeds: VecDeque::new(),
            preview_path: None,
            preview_generation: 0,
            piper_downloading: None,
            shortcut_commands: None,
            system_speech_commands: None,
            services_started: false,
            selection_generation: Arc::new(AtomicU64::new(0)),
            dismiss_generation: Arc::new(AtomicU64::new(0)),
            playback_generation: Arc::new(AtomicU64::new(0)),
        }
    }

    pub fn start_services(&mut self) {
        if self.services_started {
            return;
        }
        self.services_started = true;

        // Chromium and Electron apps only expose their accessibility tree when
        // assistive technology is enabled before they launch, so Flow turns it
        // on at startup rather than waiting for the first capture.
        std::thread::spawn(selection::enable_accessibility);

        let (sender, receiver) = tokio::sync::mpsc::unbounded_channel();
        self.shortcut_commands = Some(sender);
        let shortcut_tx = self.tx.clone();
        let preset = self.settings.hot_key;
        std::thread::spawn(move || {
            let activated_tx = shortcut_tx.clone();
            shortcuts::run(
                preset,
                receiver,
                shortcuts::Callbacks {
                    activated: Box::new(move || {
                        let _ = activated_tx.send(Message::Worker(Event::ShortcutActivated));
                    }),
                    status: Box::new(move |status| {
                        let _ = shortcut_tx.send(Message::Worker(Event::ShortcutStatus(status)));
                    }),
                },
            );
        });

        let finished_tx = self.tx.clone();
        let failed_tx = self.tx.clone();
        let word_tx = self.tx.clone();
        let finished_generation = Arc::clone(&self.playback_generation);
        let failed_generation = Arc::clone(&self.playback_generation);
        let word_generation = Arc::clone(&self.playback_generation);
        let voices_tx = self.tx.clone();
        self.system_speech_commands = Some(system_speech::start(system_speech::Callbacks {
            voices_changed: Box::new(move |voices| {
                let _ = voices_tx.send(Message::Worker(Event::SystemVoices(voices)));
            }),
            finished: Box::new(move |generation| {
                if finished_generation.load(Ordering::SeqCst) != generation {
                    return;
                }
                let _ = finished_tx.send(Message::Worker(Event::SpeechFinished(generation)));
            }),
            failed: Box::new(move |(generation, message): (u64, String)| {
                if failed_generation.load(Ordering::SeqCst) != generation {
                    return;
                }
                let _ = failed_tx.send(Message::Worker(Event::SpeechFailed {
                    generation,
                    message,
                }));
            }),
            word_range: Box::new(move |(generation, start, end): (u64, u32, u32)| {
                if word_generation.load(Ordering::SeqCst) != generation {
                    return;
                }
                let _ = word_tx.send(Message::Worker(Event::SpeechWordRange {
                    generation,
                    start,
                    end,
                }));
            }),
        }));

        if self.settings.azure_endpoint.is_some() {
            self.load_azure_voices();
        }
        if self.settings.google_api_key_configured {
            self.load_google_voices();
        }
        if self.settings.speech_source == SpeechSource::Piper {
            self.load_piper_catalog();
        }

        self.start_update_check(false);
    }

    // Selection and playback

    pub fn request_selection(&mut self) {
        let request_id = self.selection_generation.fetch_add(1, Ordering::SeqCst) + 1;
        if selection::debug_enabled() {
            eprintln!("[Flow selection] request {request_id} received");
        }
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let result =
                selection::read_focused_selection().map_err(|error| error.to_string());
            if selection::debug_enabled() {
                match &result {
                    Ok(text) => eprintln!(
                        "[Flow selection] request {request_id} resolved ({} characters)",
                        text.chars().count()
                    ),
                    Err(error) => {
                        eprintln!("[Flow selection] request {request_id} failed: {error}")
                    }
                }
            }
            let _ = tx.send(Message::Worker(Event::SelectionDone {
                request_id,
                result,
            }));
        });
    }

    pub fn apply(&mut self, audio: &mut Player, event: Event) {
        match event {
            Event::SelectionDone {
                request_id,
                result,
            } => {
                if self.selection_generation.load(Ordering::SeqCst) != request_id {
                    return;
                }
                match result {
                    Ok(text) => self.handle_selection(audio, text),
                    Err(message) => self.show_message(message),
                }
            }
            Event::ShortcutActivated => self.request_selection(),
            Event::ShortcutStatus(status) => self.shortcut_status = status,
            Event::SystemVoices(voices) => self.system_voices = voices,
            Event::SpeechFinished(generation) => {
                if self.playback_generation.load(Ordering::SeqCst) == generation {
                    self.finish_reading();
                }
            }
            Event::SpeechFailed {
                generation,
                message,
            } => {
                if self.playback_generation.load(Ordering::SeqCst) == generation {
                    self.show_message(message);
                }
            }
            Event::SpeechWordRange {
                generation,
                start,
                end,
            } => {
                if self.playback_generation.load(Ordering::SeqCst) != generation {
                    return;
                }
                if matches!(
                    self.playback_state,
                    PlaybackState::Playing | PlaybackState::Paused
                ) {
                    self.set_word_range(start as i32, end as i32);
                }
            }
            Event::AzureVoices(result) => match result {
                Ok(voices) => {
                    self.azure_voices = voices;
                    self.configuration_error.clear();
                }
                Err(message) => self.configuration_error = message,
            },
            Event::GoogleVoices(result) => match result {
                Ok(voices) => {
                    self.google_voices = voices;
                    self.configuration_error.clear();
                }
                Err(message) => self.configuration_error = message,
            },
            Event::PiperCatalog(result) => match result {
                Ok(voices) => {
                    self.piper_voices = voices;
                    self.piper_status.clear();
                }
                Err(message) => self.piper_status = message,
            },
            Event::PiperDownloaded { key, result } => {
                self.piper_downloading = None;
                match result {
                    Ok(()) => {
                        for voice in &mut self.piper_voices {
                            if voice.key == key {
                                voice.installed = true;
                            }
                        }
                        self.piper_status.clear();
                    }
                    Err(message) => self.piper_status = message,
                }
            }
            Event::PiperPreview {
                generation,
                result,
            } => {
                if generation != self.preview_generation {
                    return;
                }
                match result {
                    Ok(bytes) => match write_preview_wav(&bytes) {
                        Ok(path) => {
                            audio.play_preview(&path);
                            self.preview_path = Some(path);
                        }
                        Err(message) => self.piper_status = message,
                    },
                    Err(message) => self.piper_status = message,
                }
            }
            Event::PiperDeleted(result) => match result {
                Ok(()) => self.load_piper_catalog(),
                Err(message) => self.piper_status = message,
            },
            Event::CloudSynthesized {
                generation,
                result,
            } => {
                if self.playback_generation.load(Ordering::SeqCst) != generation {
                    return;
                }
                match result {
                    Ok(segments) => self.play_cloud_audio(audio, segments),
                    Err(message) => self.show_message(message),
                }
            }
            Event::CloudSegmentDone => self.cloud_segment_finished(audio),
            Event::WordTick {
                generation,
                start,
                end,
            } => {
                if self.playback_generation.load(Ordering::SeqCst) != generation {
                    return;
                }
                if matches!(
                    self.playback_state,
                    PlaybackState::Playing | PlaybackState::Paused
                ) {
                    self.set_word_range(start, end);
                }
            }
            Event::AutoDismiss(request_id) => {
                if self.dismiss_generation.load(Ordering::SeqCst) != request_id {
                    return;
                }
                self.selected_text.clear();
                self.plan = None;
                self.playback_state = PlaybackState::Hidden;
            }
            Event::UpdateResult { manual, result } => {
                if let Ok(version) = &result
                    && !version.is_empty()
                    && version != "up-to-date"
                {
                    self.update_ready_version = version.clone();
                }
                let notice = match result {
                    Ok(version) if version == "up-to-date" => {
                        manual.then(|| "Flow is up to date.".to_owned())
                    }
                    Ok(version) => Some(format!(
                        "Flow {version} is downloaded. Restart Flow to finish updating."
                    )),
                    Err(message) => manual.then_some(message),
                };
                // Never interrupt active reading for an update check.
                if let Some(notice) = notice {
                    if self.playback_state == PlaybackState::Hidden {
                        self.show_message(notice);
                    } else {
                        self.message = notice;
                    }
                }
            }
        }
    }

    fn handle_selection(&mut self, audio: &mut Player, text: String) {
        // The override lasts until the next capture only.
        let had_language_override = self.language_override.is_some();
        self.set_language_override(None);
        self.refresh_override_needs_route();

        let normalized = normalize(&text);
        if normalized.is_empty() {
            self.show_message(format!(
                "Select some text, then press {}.",
                hot_key_title(self.settings.hot_key)
            ));
            return;
        }
        if normalized.chars().count() > MAXIMUM_SELECTION_CHARACTERS {
            self.show_message("This selection is longer than Flow's 10-minute reading limit.");
            return;
        }
        if normalized == normalize(&self.selected_text)
            && self.settings.same_selection_action == SameSelectionAction::PauseResume
            && matches!(
                self.playback_state,
                PlaybackState::Playing | PlaybackState::Paused
            )
            && !had_language_override
        {
            self.toggle_pause(audio);
            return;
        }

        // Resetting an override requires a new Auto plan, so replay this
        // selection instead of resuming the old overridden plan.
        let plan = language::plan(&text, &self.settings);
        self.start_auto_plan(audio, text, plan);
    }

    fn start_auto_plan(&mut self, audio: &mut Player, text: String, plan: Plan) {
        if !plan.needs_language_check() {
            self.manual_route_needed = false;
            self.start_plan(audio, text, plan);
            return;
        }
        self.cancel_dismiss();
        self.stop_active_playback(audio);
        self.playback_text = playback_text(&plan, &text);
        self.set_word_range(-1, -1);
        self.selected_text = text;
        self.plan = Some(plan);
        self.manual_route_needed = true;
        self.refresh_detected_languages();
        self.playback_state = PlaybackState::AwaitingRoute;
    }

    fn refresh_detected_languages(&mut self) {
        let mut tags: Vec<String> = Vec::new();
        if let Some(plan) = &self.plan {
            for sentence in &plan.sentences {
                if let Some(tag) = &sentence.detected_language_tag
                    && !tags.contains(tag)
                {
                    tags.push(tag.clone());
                }
            }
        }
        self.detected_languages = tags;
        self.manual_route_sentence_text = self
            .plan
            .as_ref()
            .and_then(|plan| plan.sentences.iter().find(|sentence| sentence.needs_review))
            .map(|sentence| sentence.text.clone())
            .unwrap_or_default();
    }

    fn refresh_override_needs_route(&mut self) {
        self.override_needs_route = self
            .language_override
            .as_deref()
            .is_some_and(|tag| self.settings.language_route(tag).is_none());
    }

    fn start_plan(&mut self, audio: &mut Player, text: String, plan: Plan) {
        self.cancel_dismiss();
        self.stop_active_playback(audio);
        self.manual_route_needed = false;
        if (self.playback_speed - self.settings.playback_speed).abs() > f64::EPSILON {
            self.playback_speed = self.settings.playback_speed;
        }
        let (display, sentence_bases) = playback_layout(&plan, &text);
        self.playback_text = display;
        self.set_word_range(-1, -1);
        self.selected_text = text;
        self.plan = Some(plan.clone());
        self.refresh_detected_languages();
        self.playback_state = PlaybackState::Preparing;
        let generation = self.playback_generation.fetch_add(1, Ordering::SeqCst) + 1;

        match self.settings.speech_source {
            SpeechSource::System => {
                self.playback_state = PlaybackState::Playing;
                let sent = self.system_speech_commands.as_ref().is_some_and(|sender| {
                    sender
                        .send(system_speech::Command::Play {
                            generation,
                            plan,
                            sentence_bases: sentence_bases
                                .iter()
                                .map(|base| *base as u32)
                                .collect(),
                        })
                        .is_ok()
                });
                if !sent {
                    self.show_message("Flow could not start the system speech service.");
                }
            }
            SpeechSource::Azure => self.synthesize_azure(plan, generation),
            SpeechSource::Google => self.synthesize_google(plan, generation),
            SpeechSource::Piper => self.synthesize_piper(plan, generation),
        }
    }

    fn synthesize_azure(&mut self, plan: Plan, generation: u64) {
        let Some(endpoint) = self.settings.azure_endpoint.clone() else {
            self.show_message("Set up Azure Speech before choosing Azure voice.");
            return;
        };
        let settings = self.settings.clone();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let result = azure::load_key()
                .and_then(|key| azure::synthesize(&endpoint, &key, &plan, &settings))
                .map(|bytes| {
                    vec![CloudSegment {
                        bytes,
                        extension: ".mp3",
                        word_timings: Vec::new(),
                        playback_speed: None,
                    }]
                })
                .map_err(|_| {
                    "Azure could not synthesize this selection. Check the endpoint, key, and voice."
                        .to_owned()
                });
            let _ = tx.send(Message::Worker(Event::CloudSynthesized {
                generation,
                result,
            }));
        });
    }

    fn synthesize_google(&mut self, plan: Plan, generation: u64) {
        if !self.settings.google_api_key_configured {
            self.show_message("Set up Google Cloud Text-to-Speech before choosing Google voice.");
            return;
        }
        let settings = self.settings.clone();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let result = google::load_key()
                .and_then(|key| {
                    google::synthesize(&key, &plan, settings.word_highlighting_enabled)
                })
                .map(|segments| {
                    segments
                        .into_iter()
                        .map(|segment| CloudSegment {
                            bytes: segment.audio,
                            extension: ".mp3",
                            word_timings: segment.word_timings,
                            playback_speed: segment.playback_speed,
                        })
                        .collect()
                })
                .map_err(|_| {
                    "Google Cloud could not synthesize this selection. Check the API key and voice."
                        .to_owned()
                });
            let _ = tx.send(Message::Worker(Event::CloudSynthesized {
                generation,
                result,
            }));
        });
    }

    fn synthesize_piper(&mut self, plan: Plan, generation: u64) {
        let Some(engine) = piper::find_engine() else {
            self.show_message(
                "Flow could not find the Piper speech engine. Install piper, or run Flow from the AppImage that bundles it.",
            );
            return;
        };
        let mut voice_keys = Vec::with_capacity(plan.sentences.len());
        for sentence in &plan.sentences {
            let key = sentence
                .route
                .piper_voice_name
                .clone()
                .or_else(|| self.settings.piper_voice_name.clone());
            let Some(key) = key else {
                self.show_message("Choose a Piper voice in Flow's settings before reading.");
                return;
            };
            if !piper::is_installed(&key) {
                self.show_message(format!(
                    "The {key} voice is not downloaded yet. Get it from Flow's settings."
                ));
                return;
            }
            voice_keys.push(key);
        }
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let result = plan
                .sentences
                .iter()
                .zip(&voice_keys)
                .map(|(sentence, key)| {
                    piper::synthesize(&engine, key, &sentence.text).map(|bytes| CloudSegment {
                        bytes,
                        extension: ".wav",
                        word_timings: Vec::new(),
                        playback_speed: None,
                    })
                })
                .collect::<Result<Vec<_>, String>>();
            let _ = tx.send(Message::Worker(Event::CloudSynthesized {
                generation,
                result,
            }));
        });
    }

    fn play_cloud_audio(&mut self, audio: &mut Player, segments: Vec<CloudSegment>) {
        if !audio.available() {
            self.show_message("Flow could not start audio playback on this device.");
            return;
        }
        let staged = segments
            .into_iter()
            .map(|segment| {
                tempfile::Builder::new()
                    .prefix("flow-")
                    .suffix(segment.extension)
                    .tempfile()
                    .and_then(|mut file| {
                        file.write_all(&segment.bytes)?;
                        Ok((
                            file.into_temp_path(),
                            segment.word_timings,
                            segment.playback_speed,
                        ))
                    })
            })
            .collect::<Result<Vec<_>, _>>();
        match staged {
            Ok(paths) if !paths.is_empty() => {
                let mut audio_paths = VecDeque::new();
                let mut word_timings = VecDeque::new();
                let mut segment_speeds = VecDeque::new();
                for (path, timings, speed) in paths {
                    audio_paths.push_back(path);
                    word_timings.push_back(timings);
                    segment_speeds.push_back(speed);
                }
                self.queued_audio_paths = audio_paths;
                self.queued_word_timings = word_timings;
                self.queued_segment_speeds = segment_speeds;
                self.play_next_cloud_segment(audio);
            }
            _ => self.show_message("The speech service returned audio that Flow could not play."),
        }
    }

    fn play_next_cloud_segment(&mut self, audio: &mut Player) {
        self.audio_path = self.queued_audio_paths.pop_front();
        let Some(path) = self.audio_path.as_ref().map(|path| path.to_path_buf()) else {
            self.finish_reading();
            return;
        };
        let timings = self.queued_word_timings.pop_front().unwrap_or_default();
        let speed = self
            .queued_segment_speeds
            .pop_front()
            .unwrap_or(None)
            .unwrap_or(self.settings.playback_speed);
        let generation = self.playback_generation.load(Ordering::SeqCst);
        self.playback_state = PlaybackState::Playing;
        let tx = self.tx.clone();
        audio.play_file(
            &path,
            speed.clamp(0.5, 4.0),
            move || {
                let _ = tx.send(Message::Worker(Event::CloudSegmentDone));
            },
        );
        if !timings.is_empty() {
            let tx = self.tx.clone();
            std::thread::spawn(move || {
                let started = std::time::Instant::now();
                for timing in timings {
                    let wait = Duration::from_secs_f64(
                        (timing.time_seconds / speed.clamp(0.5, 4.0)).max(0.0),
                    );
                    let elapsed = started.elapsed();
                    if wait > elapsed {
                        std::thread::sleep(wait - elapsed);
                    }
                    let _ = tx.send(Message::Worker(Event::WordTick {
                        generation,
                        start: timing.start as i32,
                        end: timing.end as i32,
                    }));
                }
            });
        }
    }

    fn cloud_segment_finished(&mut self, audio: &mut Player) {
        if !matches!(
            self.playback_state,
            PlaybackState::Playing | PlaybackState::Paused
        ) {
            return;
        }
        self.audio_path = None;
        self.play_next_cloud_segment(audio);
    }

    // Transport controls

    pub fn toggle_pause(&mut self, audio: &mut Player) {
        match self.playback_state {
            PlaybackState::Playing => {
                if let Some(sender) = &self.system_speech_commands {
                    let _ = sender.send(system_speech::Command::Pause);
                }
                audio.pause();
                self.playback_state = PlaybackState::Paused;
            }
            PlaybackState::Paused => {
                if let Some(sender) = &self.system_speech_commands {
                    let _ = sender.send(system_speech::Command::Resume);
                }
                audio.resume();
                self.playback_state = PlaybackState::Playing;
            }
            _ => {}
        }
    }

    pub fn stop_reading(&mut self, audio: &mut Player) {
        self.cancel_dismiss();
        self.stop_active_playback(audio);
        self.selected_text.clear();
        self.playback_text.clear();
        self.plan = None;
        self.refresh_detected_languages();
        self.set_word_range(-1, -1);
        self.playback_state = PlaybackState::Hidden;
    }

    fn stop_active_playback(&mut self, audio: &mut Player) {
        self.playback_generation.fetch_add(1, Ordering::SeqCst);
        if let Some(sender) = &self.system_speech_commands {
            let _ = sender.send(system_speech::Command::Stop);
        }
        audio.stop();
        self.audio_path = None;
        self.queued_audio_paths.clear();
        self.queued_word_timings.clear();
        self.queued_segment_speeds.clear();
    }

    fn finish_reading(&mut self) {
        if !matches!(
            self.playback_state,
            PlaybackState::Playing | PlaybackState::Paused
        ) {
            return;
        }
        self.audio_path = None;
        self.queued_audio_paths.clear();
        self.queued_word_timings.clear();
        self.queued_segment_speeds.clear();
        self.playback_state = PlaybackState::Finished;
        self.dismiss_after_delay();
    }

    pub fn show_message(&mut self, message: impl Into<String>) {
        self.cancel_dismiss();
        if let Some(sender) = &self.system_speech_commands {
            let _ = sender.send(system_speech::Command::Stop);
        }
        self.playback_generation.fetch_add(1, Ordering::SeqCst);
        self.selected_text.clear();
        self.plan = None;
        self.refresh_detected_languages();
        self.set_word_range(-1, -1);
        self.message = message.into();
        self.playback_state = PlaybackState::Message;
        self.dismiss_after_delay();
    }

    fn dismiss_after_delay(&mut self) {
        let request_id = self.dismiss_generation.fetch_add(1, Ordering::SeqCst) + 1;
        let delay = self.settings.popup_dismiss_seconds.clamp(3.0, 30.0);
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs_f64(delay));
            let _ = tx.send(Message::Worker(Event::AutoDismiss(request_id)));
        });
    }

    fn cancel_dismiss(&self) {
        self.dismiss_generation.fetch_add(1, Ordering::SeqCst);
    }

    // Language check

    pub fn set_route_for_language(&mut self, audio: &mut Player, language_tag: &str, route_id: Uuid) {
        let Some(route) = self
            .settings
            .all_language_routes()
            .into_iter()
            .find(|route| route.id == route_id)
        else {
            return;
        };
        let Some(mut plan) = self.plan.take() else {
            return;
        };
        for sentence in plan.sentences.iter_mut() {
            if sentence.detected_language_tag.as_deref() == Some(language_tag) {
                sentence.route = route.clone();
                sentence.needs_review = false;
            }
        }
        self.plan = Some(plan.clone());
        self.start_plan(audio, self.selected_text.clone(), plan);
    }

    pub fn set_text_language_override(&mut self, audio: &mut Player, tag: Option<String>) {
        if tag == self.language_override {
            return;
        }
        self.set_language_override(tag.clone());
        self.refresh_override_needs_route();
        match (self.playback_state, &tag) {
            (
                PlaybackState::Preparing
                | PlaybackState::Playing
                | PlaybackState::Paused
                | PlaybackState::AwaitingRoute,
                Some(tag),
            ) => {
                if self.selected_text.is_empty() {
                    return;
                }
                let plan = language::plan_with_override(
                    &self.selected_text,
                    &self.settings,
                    Some(tag),
                );
                if self.override_needs_route {
                    // Never speak with a guessed voice: hold playback
                    // until a route is chosen for this language.
                    self.cancel_dismiss();
                    self.stop_active_playback(audio);
                    self.plan = Some(plan);
                    self.refresh_detected_languages();
                    self.playback_state = PlaybackState::AwaitingRoute;
                } else {
                    self.start_plan(audio, self.selected_text.clone(), plan);
                }
            }
            (
                PlaybackState::Preparing
                | PlaybackState::Playing
                | PlaybackState::Paused
                | PlaybackState::AwaitingRoute,
                None,
            ) => {
                if self.selected_text.is_empty() {
                    return;
                }
                let plan = language::plan(&self.selected_text, &self.settings);
                self.start_auto_plan(audio, self.selected_text.clone(), plan);
            }
            _ => {}
        }
    }

    pub fn set_override_route(&mut self, audio: &mut Player, route_id: Uuid) {
        if self.language_override.is_none() && !self.manual_route_needed {
            return;
        }
        let route = self
            .settings
            .all_language_routes()
            .into_iter()
            .find(|route| route.id == route_id);
        let Some(route) = route else {
            return;
        };
        let Some(mut plan) = self.plan.take() else {
            return;
        };
        if self.language_override.is_some() {
            for sentence in plan.sentences.iter_mut() {
                sentence.route = route.clone();
                sentence.needs_review = false;
            }
            self.manual_route_needed = false;
            self.plan = Some(plan.clone());
            self.start_plan(audio, self.selected_text.clone(), plan);
            return;
        }

        let Some(sentence) = plan
            .sentences
            .iter_mut()
            .find(|sentence| sentence.needs_review)
        else {
            return;
        };
        sentence.route = route;
        sentence.needs_review = false;
        if plan.needs_language_check() {
            self.plan = Some(plan);
            self.refresh_detected_languages();
            return;
        }
        self.manual_route_needed = false;
        self.plan = Some(plan.clone());
        self.start_plan(audio, self.selected_text.clone(), plan);
    }

    // Settings

    pub fn apply_setting(&mut self, key: &str, value: &str) {
        let previous_hotkey = self.settings.hot_key;
        match key {
            "speechSource" => {
                self.settings.speech_source = match value {
                    "azure" => SpeechSource::Azure,
                    "google" => SpeechSource::Google,
                    "piper" => SpeechSource::Piper,
                    _ => SpeechSource::System,
                };
                self.configuration_error.clear();
                if self.settings.speech_source == SpeechSource::Piper
                    && self.piper_voices.is_empty()
                {
                    self.load_piper_catalog();
                }
            }
            "hotKey" => {
                self.settings.hot_key = match value {
                    "altSuperSpace" => HotKeyPreset::AltSuperSpace,
                    "controlAltR" => HotKeyPreset::ControlAltR,
                    _ => HotKeyPreset::AltSuperR,
                };
            }
            "systemVoiceName" => {
                self.settings.system_voice_name = nonempty(value);
            }
            "systemSpeechRate" => {
                if let Ok(rate) = value.parse::<f64>() {
                    self.settings.system_speech_rate = rate.clamp(-1.0, 1.0);
                }
            }
            "popupDismissSeconds" => {
                if let Ok(seconds) = value.parse::<f64>() {
                    self.settings.popup_dismiss_seconds = seconds.clamp(3.0, 30.0);
                }
            }
            "playbackSpeed" => {
                if let Ok(speed) = value.parse::<f64>() {
                    let clamped = speed.clamp(0.5, 4.0);
                    self.settings.playback_speed = clamped;
                    self.playback_speed = clamped;
                }
            }
            "sameSelectionAction" => {
                self.settings.same_selection_action = if value == "restart" {
                    SameSelectionAction::Restart
                } else {
                    SameSelectionAction::PauseResume
                };
            }
            "wordHighlightingEnabled" => self.settings.word_highlighting_enabled = value == "true",
            "azureVoiceName" => self.settings.azure_voice_name = value.into(),
            "azureSpeechRate" => {
                if let Ok(rate) = value.parse::<f64>() {
                    self.settings.azure_speech_rate = rate.clamp(-1.0, 1.0);
                }
            }
            "azureVoiceMode" => {
                self.settings.azure_voice_mode = if value == "perLanguage" {
                    AzureVoiceMode::PerLanguage
                } else {
                    AzureVoiceMode::Multilingual
                };
            }
            "googleVoiceName" => self.settings.google_voice_name = nonempty(value),
            "googleSpeechRate" => {
                if let Ok(rate) = value.parse::<f64>() {
                    self.settings.google_speech_rate = rate.clamp(-1.0, 1.0);
                }
            }
            "piperVoiceName" => self.settings.piper_voice_name = nonempty(value),
            "defaultLanguageTag" => {
                self.settings.default_language_tag = value.into();
                self.settings.google_voice_name = None;
            }
            "languageSwitchingEnabled" => {
                self.settings.language_switching_enabled = value == "true"
            }
            _ => return,
        }
        if previous_hotkey != self.settings.hot_key
            && let Some(sender) = &self.shortcut_commands
        {
            let _ = sender.send(shortcuts::Command::Change(self.settings.hot_key));
        }
        self.persist_settings();
    }

    pub fn apply_route_setting(&mut self, route_id: Uuid, field: &str, value: &str) {
        if route_id == DEFAULT_LANGUAGE_ROUTE_ID {
            match field {
                "systemVoiceName" => self.settings.system_voice_name = nonempty(value),
                "systemSpeechRate" => {
                    if let Ok(rate) = value.parse::<f64>() {
                        self.settings.system_speech_rate = rate.clamp(-1.0, 1.0);
                    }
                }
                "azureVoiceName" => self.settings.azure_voice_name = value.into(),
                "azureSpeechRate" => {
                    if let Ok(rate) = value.parse::<f64>() {
                        self.settings.azure_speech_rate = rate.clamp(-1.0, 1.0);
                    }
                }
                "googleVoiceName" => self.settings.google_voice_name = nonempty(value),
                "googleSpeechRate" => {
                    if let Ok(rate) = value.parse::<f64>() {
                        self.settings.google_speech_rate = rate.clamp(-1.0, 1.0);
                    }
                }
                "piperVoiceName" => self.settings.piper_voice_name = nonempty(value),
                _ => return,
            }
        } else if let Some(route) = self
            .settings
            .language_routes
            .iter_mut()
            .find(|r| r.id == route_id)
        {
            match field {
                "systemVoiceName" => route.system_voice_name = nonempty(value),
                "systemSpeechRate" => {
                    if let Ok(rate) = value.parse::<f64>() {
                        route.system_speech_rate = rate.clamp(-1.0, 1.0);
                    }
                }
                "azureVoiceName" => route.azure_voice_name = nonempty(value),
                "azureSpeechRate" => {
                    if let Ok(rate) = value.parse::<f64>() {
                        route.azure_speech_rate = rate.clamp(-1.0, 1.0);
                    }
                }
                "googleVoiceName" => route.google_voice_name = nonempty(value),
                "googleSpeechRate" => {
                    if let Ok(rate) = value.parse::<f64>() {
                        route.google_speech_rate = rate.clamp(-1.0, 1.0);
                    }
                }
                "piperVoiceName" => route.piper_voice_name = nonempty(value),
                "playbackSpeed" => {
                    route.playback_speed = if value.is_empty() {
                        None
                    } else {
                        value.parse::<f64>().ok().map(|speed| speed.clamp(0.5, 4.0))
                    };
                }
                _ => return,
            }
        } else {
            return;
        }
        self.persist_settings();
    }

    pub fn add_language_route(&mut self, language_tag: &str) {
        let supported = language::supported_languages()
            .iter()
            .any(|(tag, _)| tag.eq_ignore_ascii_case(language_tag));
        let duplicate = self
            .settings
            .all_language_routes()
            .iter()
            .any(|route| language_base(&route.language_tag) == language_base(language_tag));
        if supported && !duplicate {
            let mut route = LanguageRoute::new(language_tag);
            route.system_voice_name = self
                .system_voices
                .iter()
                .find(|voice| language_base(&voice.language_tag) == language_base(language_tag))
                .map(|voice| voice.name.clone());
            route.azure_voice_name = self
                .azure_voices
                .iter()
                .find(|voice| {
                    language_base(&voice.locale) == language_base(language_tag)
                        || voice
                            .secondary_locales
                            .iter()
                            .any(|locale| language_base(locale) == language_base(language_tag))
                })
                .map(|voice| voice.short_name.clone())
                .or_else(|| Some(self.settings.azure_voice_name.clone()));
            route.google_voice_name = self
                .google_voices
                .iter()
                .find(|voice| {
                    voice
                        .language_codes
                        .iter()
                        .any(|locale| language_base(locale) == language_base(language_tag))
                })
                .map(|voice| voice.name.clone());
            route.piper_voice_name = self
                .piper_voices
                .iter()
                .find(|voice| language_base(&voice.language_code) == language_base(language_tag))
                .map(|voice| voice.key.clone());
            route.azure_speech_rate = self.settings.azure_speech_rate;
            route.google_speech_rate = self.settings.google_speech_rate;
            self.settings.language_routes.push(route);
            self.persist_settings();
        }
    }

    pub fn remove_language_route(&mut self, route_id: Uuid) {
        self.settings
            .language_routes
            .retain(|route| route.id != route_id);
        self.persist_settings();
    }

    pub fn save_azure(&mut self, raw_endpoint: &str, raw_key: &str) {
        let result = azure::normalize_endpoint(raw_endpoint)
            .and_then(|endpoint| azure::validate_key(raw_key).map(|key| (endpoint, key)))
            .and_then(|(endpoint, key)| {
                azure::save_key(&key)?;
                Ok(endpoint)
            });
        match result {
            Ok(endpoint) => {
                self.settings.azure_endpoint = Some(endpoint);
                self.configuration_error.clear();
                self.persist_settings();
                self.load_azure_voices();
            }
            Err(error) => self.configuration_error = error.to_string(),
        }
    }

    pub fn clear_azure(&mut self) {
        azure::clear_key();
        self.settings.azure_endpoint = None;
        self.azure_voices.clear();
        if self.settings.speech_source == SpeechSource::Azure {
            self.settings.speech_source = SpeechSource::System;
        }
        self.persist_settings();
    }

    pub fn load_azure_voices(&mut self) {
        let Some(endpoint) = self.settings.azure_endpoint.clone() else {
            return;
        };
        self.configuration_error.clear();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let result = azure::load_key()
                .and_then(|key| azure::list_voices(&endpoint, &key))
                .map_err(|_| {
                    "Flow could not load Azure voices. Check the endpoint and key.".to_owned()
                });
            let _ = tx.send(Message::Worker(Event::AzureVoices(result)));
        });
    }

    pub fn save_google(&mut self, raw_key: &str) {
        match google::validate_key(raw_key).and_then(|key| google::save_key(&key)) {
            Ok(()) => {
                self.settings.google_api_key_configured = true;
                self.configuration_error.clear();
                self.persist_settings();
                self.load_google_voices();
            }
            Err(error) => self.configuration_error = error.to_string(),
        }
    }

    pub fn clear_google(&mut self) {
        google::clear_key();
        self.settings.google_api_key_configured = false;
        self.google_voices.clear();
        if self.settings.speech_source == SpeechSource::Google {
            self.settings.speech_source = SpeechSource::System;
        }
        self.persist_settings();
    }

    pub fn load_google_voices(&mut self) {
        if !self.settings.google_api_key_configured {
            return;
        }
        self.configuration_error.clear();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let result = google::load_key()
                .and_then(|key| google::list_voices(&key))
                .map_err(|_| {
                    "Flow could not load Google voices. Check the API key and confirm that Cloud Text-to-Speech is enabled."
                        .to_owned()
                });
            let _ = tx.send(Message::Worker(Event::GoogleVoices(result)));
        });
    }

    pub fn load_piper_catalog(&mut self) {
        self.piper_status = "Loading Piper voices…".into();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let _ = tx.send(Message::Worker(Event::PiperCatalog(piper::fetch_catalog())));
        });
    }

    pub fn start_piper_download(&mut self, key: &str) {
        if self
            .piper_downloading
            .as_deref()
            .is_some_and(|active| active == key)
        {
            return;
        }
        self.piper_downloading = Some(key.to_owned());
        self.piper_status = format!("Downloading {key}…");
        let key = key.to_owned();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let result = piper::download_voice(&key);
            let _ = tx.send(Message::Worker(Event::PiperDownloaded { key, result }));
        });
    }

    pub fn preview_piper_voice(&mut self, audio: &mut Player, key: &str) {
        if !piper::is_installed(key) {
            return;
        }
        let Some(engine) = piper::find_engine() else {
            self.piper_status = "Flow could not find the Piper speech engine.".into();
            return;
        };
        self.preview_generation += 1;
        let generation = self.preview_generation;
        let key = key.to_owned();
        let tx = self.tx.clone();
        let _ = audio;
        std::thread::spawn(move || {
            let result = piper::synthesize(&engine, &key, PREVIEW_TEXT);
            let _ = tx.send(Message::Worker(Event::PiperPreview {
                generation,
                result,
            }));
        });
    }

    pub fn delete_piper_voice(&mut self, key: &str) {
        let key = key.to_owned();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let _ = tx.send(Message::Worker(Event::PiperDeleted(piper::delete_voice(
                &key,
            ))));
        });
    }

    pub fn play_test_voice(&mut self, audio: &mut Player) {
        let text = "Flow is ready to read selected text.".to_owned();
        let plan = language::single_sentence(&text, &self.settings);
        self.start_plan(audio, text, plan);
    }

    pub fn set_playback_speed(&mut self, audio: &mut Player, speed: f64) {
        let clamped = speed.clamp(0.5, 4.0);
        if (self.settings.playback_speed - clamped).abs() < f64::EPSILON {
            return;
        }
        self.settings.playback_speed = clamped;
        self.playback_speed = clamped;
        audio.set_rate(clamped);
        self.persist_settings();
    }

    pub fn start_update_check(&mut self, manual: bool) {
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let result = updates::check().map(|outcome| match outcome {
                updates::Outcome::UpToDate => "up-to-date".to_owned(),
                updates::Outcome::Staged(version) => version,
            });
            let _ = tx.send(Message::Worker(Event::UpdateResult { manual, result }));
        });
    }

    pub fn restart_to_update(&mut self) {
        if self.update_ready_version.is_empty() {
            return;
        }
        self.persist_settings();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            if let Err(message) = updates::apply_staged_and_restart() {
                let _ = tx.send(Message::Worker(Event::UpdateResult {
                    manual: true,
                    result: Err(message),
                }));
            }
        });
    }

    fn persist_settings(&mut self) {
        if settings::save(&self.settings).is_err() {
            self.configuration_error = "Flow could not save its settings.".into();
        }
    }

    fn set_language_override(&mut self, value: Option<String>) {
        self.language_override = value;
    }

    fn set_word_range(&mut self, start: i32, end: i32) {
        self.current_word_start = start;
        self.current_word_end = end;
    }
}

impl Drop for Controller {
    fn drop(&mut self) {
        if let Some(sender) = &self.shortcut_commands {
            let _ = sender.send(shortcuts::Command::Stop);
        }
        if let Some(sender) = &self.system_speech_commands {
            let _ = sender.send(system_speech::Command::Shutdown);
        }
    }
}

fn hot_key_title(preset: HotKeyPreset) -> &'static str {
    match preset {
        HotKeyPreset::AltSuperR => {
            if cfg!(target_os = "windows") {
                "Alt+Win+R"
            } else {
                "Alt-Super-R"
            }
        }
        HotKeyPreset::AltSuperSpace => {
            if cfg!(target_os = "windows") {
                "Alt+Win+Space"
            } else {
                "Alt-Super-Space"
            }
        }
        HotKeyPreset::ControlAltR => "Control-Alt-R",
    }
}

pub fn normalize(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn nonempty(value: &str) -> Option<String> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

const PREVIEW_TEXT: &str = "Hello! This is how this voice sounds.";

/// Writes a preview sample to a temp WAV that stays alive through
/// `preview_path` until the next preview replaces it.
fn write_preview_wav(bytes: &[u8]) -> Result<TempPath, String> {
    tempfile::Builder::new()
        .prefix("flow-preview-")
        .suffix(".wav")
        .tempfile()
        .and_then(|mut file| {
            file.write_all(bytes)?;
            file.flush()?;
            Ok(file.into_temp_path())
        })
        .map_err(|_| "Flow could not save the voice preview.".to_owned())
}

/// Retains source paragraph breaks without changing the one-code-unit sentence
/// separators used by the word-boundary offsets. Alongside the display text it
/// returns each sentence's UTF-16 offset, the coordinate space shared by the
/// Google timings and Speech Dispatcher index marks.
fn playback_layout(plan: &Plan, source: &str) -> (String, Vec<usize>) {
    if plan.sentences.len() < 2 {
        return (
            plan.sentences
                .first()
                .map_or_else(|| source.into(), |sentence| sentence.text.clone()),
            vec![0],
        );
    }

    let mut ranges = Vec::with_capacity(plan.sentences.len());
    let mut search_start = 0;
    for sentence in &plan.sentences {
        let Some(offset) = source[search_start..].find(&sentence.text) else {
            return joined_sentences(plan);
        };
        let start = search_start + offset;
        let end = start + sentence.text.len();
        ranges.push(start..end);
        search_start = end;
    }

    let mut text = String::new();
    let mut offsets = Vec::with_capacity(plan.sentences.len());
    for (index, sentence) in plan.sentences.iter().enumerate() {
        offsets.push(text.encode_utf16().count());
        text.push_str(&sentence.text);
        if index + 1 < plan.sentences.len() {
            let gap = &source[ranges[index].end..ranges[index + 1].start];
            text.push(if gap.matches('\n').count() >= 2 {
                '\n'
            } else {
                ' '
            });
        }
    }
    (text, offsets)
}

fn playback_text(plan: &Plan, source: &str) -> String {
    playback_layout(plan, source).0
}

fn joined_sentences(plan: &Plan) -> (String, Vec<usize>) {
    let text = plan
        .sentences
        .iter()
        .map(|sentence| sentence.text.as_str())
        .collect::<Vec<_>>()
        .join(" ");
    let mut offsets = Vec::with_capacity(plan.sentences.len());
    let mut offset = 0usize;
    for sentence in &plan.sentences {
        offsets.push(offset);
        offset += sentence.text.encode_utf16().count() + 1;
    }
    (text, offsets)
}
