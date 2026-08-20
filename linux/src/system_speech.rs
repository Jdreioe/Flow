use std::{
    collections::VecDeque,
    io,
    os::unix::net::UnixStream,
    sync::mpsc::{self, Receiver, Sender},
    time::{Duration, Instant},
};

use serde::Serialize;
use ssip_client_async::{
    Client, ClientError, ClientName, ClientScope, MessageScope, NotificationType, Priority,
    Response, SynthesisVoice, fifo::synchronous::Builder,
};

use flow_core::{
    language::{Plan, Sentence},
    model::language_base,
};

const COMMON_VARIANTS: &[&str] = &["female1", "female2", "male1", "male2"];
const RESPONSE_TIMEOUT: Duration = Duration::from_secs(3);

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

struct Playback {
    generation: u64,
    sentences: VecDeque<Sentence>,
    current_message: Option<u32>,
}

pub fn start(callbacks: Callbacks) -> Sender<Command> {
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || run(receiver, callbacks));
    sender
}

fn run(receiver: Receiver<Command>, callbacks: Callbacks) {
    let (mut client, voices) = match initialize() {
        Ok(connection) => connection,
        Err(error) => {
            run_unavailable(receiver, callbacks, error);
            return;
        }
    };

    (callbacks.voices_changed)(visible_voices(&voices));
    let mut playback: Option<Playback> = None;
    loop {
        while let Ok(command) = receiver.try_recv() {
            match command {
                Command::Play { generation, plan } => {
                    cancel(&mut client);
                    playback = Some(Playback {
                        generation,
                        sentences: plan.sentences.into(),
                        current_message: None,
                    });
                    speak_next(&mut client, &voices, &mut playback, &callbacks);
                }
                Command::Pause => {
                    if playback.is_some() {
                        let _ = client.pause(MessageScope::Last);
                    }
                }
                Command::Resume => {
                    if playback.is_some() {
                        let _ = client.resume(MessageScope::Last);
                    }
                }
                Command::Stop => {
                    playback = None;
                    cancel(&mut client);
                }
                Command::Shutdown => {
                    cancel(&mut client);
                    let _ = client.quit();
                    return;
                }
            }
        }

        match client.receive() {
            Ok(Response::EventEnd(event)) => {
                let message_id = event.message.parse::<u32>().ok();
                if playback.as_ref().and_then(|item| item.current_message) == message_id {
                    speak_next(&mut client, &voices, &mut playback, &callbacks);
                }
            }
            Ok(Response::EventCanceled(_)) => {}
            Ok(_) => {}
            Err(error) if is_idle(&error) => {}
            Err(_) if playback.is_none() => {}
            Err(_) => {
                let generation = playback.as_ref().map(|item| item.generation);
                playback = None;
                if let Some(generation) = generation {
                    (callbacks.failed)((
                        generation,
                        "Speech Dispatcher ended playback unexpectedly.".to_owned(),
                    ));
                }
            }
        }
    }
}

fn initialize() -> Result<(Client<UnixStream>, Vec<SynthesisVoice>), String> {
    let mut builder = Builder::new();
    builder.timeout(Duration::from_millis(100));
    let mut client = match builder.build() {
        Ok(client) => client,
        Err(_) => {
            builder
                .with_spawn()
                .map_err(|_| "Flow could not start Speech Dispatcher.".to_owned())?;
            std::thread::sleep(Duration::from_millis(250));
            builder
                .build()
                .map_err(|_| "Flow could not connect to Speech Dispatcher.".to_owned())?
        }
    };

    client
        .set_client_name(ClientName::new("flow", "system-speech"))
        .map_err(client_error)?;
    expect(&mut client, |response| {
        matches!(response, Response::ClientNameSet)
    })?;

    client.list_output_modules().map_err(client_error)?;
    let modules = match receive(&mut client)? {
        Response::OutputModulesListSent(modules) => modules,
        _ => return Err("Speech Dispatcher returned an invalid module list.".to_owned()),
    };
    let module = modules
        .iter()
        .find(|module| module.as_str() == "espeak-ng")
        .or_else(|| modules.iter().find(|module| module.as_str() == "espeak"))
        .or_else(|| modules.first())
        .ok_or_else(|| "Speech Dispatcher has no working speech module.".to_owned())?;
    client
        .set_output_module(ClientScope::Current, module)
        .map_err(client_error)?;
    expect(&mut client, |response| {
        matches!(response, Response::OutputModuleSet)
    })?;

    client.list_synthesis_voices().map_err(client_error)?;
    let voices = match receive(&mut client)? {
        Response::VoicesListSent(voices) if !voices.is_empty() => voices,
        _ => return Err("The selected speech module did not provide any voices.".to_owned()),
    };
    client.set_priority(Priority::Text).map_err(client_error)?;
    expect(&mut client, |response| {
        matches!(response, Response::PrioritySet)
    })?;
    client
        .set_notification(NotificationType::All, true)
        .map_err(client_error)?;
    expect(&mut client, |response| {
        matches!(response, Response::NotificationSet)
    })?;

    Ok((client, voices))
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

fn speak_next(
    client: &mut Client<UnixStream>,
    voices: &[SynthesisVoice],
    playback: &mut Option<Playback>,
    callbacks: &Callbacks,
) {
    let Some(active) = playback.as_mut() else {
        return;
    };
    let Some(sentence) = active.sentences.pop_front() else {
        let generation = active.generation;
        *playback = None;
        (callbacks.finished)(generation);
        return;
    };

    match configure(client, voices, &sentence).and_then(|()| speak(client, &sentence.text)) {
        Ok(message_id) => active.current_message = Some(message_id),
        Err(error) => {
            let generation = active.generation;
            *playback = None;
            (callbacks.failed)((generation, error));
        }
    }
}

fn configure(
    client: &mut Client<UnixStream>,
    voices: &[SynthesisVoice],
    sentence: &Sentence,
) -> Result<(), String> {
    let requested_language = sentence.route.language_tag.replace('_', "-");
    client
        .set_language(ClientScope::Current, &requested_language)
        .map_err(client_error)?;
    expect(client, |response| matches!(response, Response::LanguageSet))?;

    let rate = (sentence.route.system_speech_rate * 100.0).round() as i8;
    client
        .set_rate(ClientScope::Current, rate)
        .map_err(client_error)?;
    expect(client, |response| matches!(response, Response::RateSet))?;

    let selected = sentence
        .route
        .system_voice_name
        .as_deref()
        .and_then(|name| voices.iter().find(|voice| voice.name == name));
    let default = voices
        .iter()
        .filter(|voice| voice.dialect.is_none())
        .find(|voice| {
            voice
                .language
                .as_deref()
                .is_some_and(|language| tags_match(language, &requested_language))
        })
        .or_else(|| {
            voices.iter().find(|voice| {
                voice.language.as_deref().is_some_and(|language| {
                    language_base(language) == language_base(&requested_language)
                })
            })
        });
    if let Some(voice) = selected.or(default) {
        client
            .set_synthesis_voice(ClientScope::Current, &voice.name)
            .map_err(client_error)?;
        expect(client, |response| matches!(response, Response::VoiceSet))?;
    }
    Ok(())
}

fn speak(client: &mut Client<UnixStream>, text: &str) -> Result<u32, String> {
    client.speak().map_err(client_error)?;
    expect(client, |response| {
        matches!(response, Response::ReceivingData)
    })?;
    let normalized = text
        .replace('\0', " ")
        .lines()
        .collect::<Vec<_>>()
        .join(" ");
    client.send_line(&normalized).map_err(client_error)?;
    receive_message_id(client)
}

fn cancel(client: &mut Client<UnixStream>) {
    if client.cancel(MessageScope::Last).is_ok() {
        let _ = expect(client, |response| matches!(response, Response::Canceled));
    }
}

fn expect(
    client: &mut Client<UnixStream>,
    expected: impl Fn(&Response) -> bool,
) -> Result<(), String> {
    let deadline = Instant::now() + RESPONSE_TIMEOUT;
    loop {
        let response = receive_until(client, deadline)?;
        if expected(&response) {
            return Ok(());
        }
    }
}

fn receive(client: &mut Client<UnixStream>) -> Result<Response, String> {
    receive_until(client, Instant::now() + RESPONSE_TIMEOUT)
}

fn receive_until(client: &mut Client<UnixStream>, deadline: Instant) -> Result<Response, String> {
    loop {
        match client.receive() {
            Ok(response) => return Ok(response),
            Err(error) if is_idle(&error) && Instant::now() < deadline => {}
            Err(error) => return Err(client_error(error)),
        }
    }
}

fn receive_message_id(client: &mut Client<UnixStream>) -> Result<u32, String> {
    let deadline = Instant::now() + RESPONSE_TIMEOUT;
    loop {
        match client.receive_message_id() {
            Ok(message_id) => return Ok(message_id),
            Err(error) if is_idle(&error) && Instant::now() < deadline => {}
            Err(error) => return Err(client_error(error)),
        }
    }
}

fn is_idle(error: &ClientError) -> bool {
    matches!(error, ClientError::NotReady)
        || matches!(error, ClientError::Io(error) if matches!(error.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut))
}

fn client_error(error: ClientError) -> String {
    format!("Speech Dispatcher error: {error}")
}

fn visible_voices(voices: &[SynthesisVoice]) -> Vec<SystemVoice> {
    let mut result = voices
        .iter()
        .filter(|voice| {
            voice.language.as_deref().is_some_and(|language| {
                flow_core::language::supported_languages()
                    .iter()
                    .any(|(tag, _)| language_base(language) == language_base(tag))
            })
        })
        .filter(|voice| {
            voice.dialect.is_none()
                || voice
                    .dialect
                    .as_deref()
                    .is_some_and(|variant| COMMON_VARIANTS.contains(&variant))
        })
        .filter_map(|voice| {
            voice.language.as_ref().map(|language| SystemVoice {
                name: voice.name.clone(),
                language_tag: language.replace('_', "-"),
            })
        })
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn language_tags_accept_underscore_or_dash() {
        assert!(tags_match("en_US", "en-US"));
        assert!(!tags_match("en_GB", "en-US"));
    }

    #[test]
    fn visible_voices_keep_defaults_and_common_variants() {
        let voices = vec![
            SynthesisVoice::new("English", Some("en-US"), None),
            SynthesisVoice::new("English+female1", Some("en-US"), Some("female1")),
            SynthesisVoice::new("English+robot", Some("en-US"), Some("robot")),
        ];

        assert_eq!(visible_voices(&voices).len(), 2);
    }
}
