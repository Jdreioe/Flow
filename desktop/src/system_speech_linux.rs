use std::{
    collections::VecDeque,
    io,
    os::unix::net::UnixStream,
    sync::mpsc::{self, Receiver, Sender},
    time::{Duration, Instant},
};

use ssip_client_async::{
    Client, ClientError, ClientName, ClientScope, MessageScope, NotificationType, Priority,
    Response, SynthesisVoice, fifo::synchronous::Builder,
};

use flow_core::{language::Sentence, model::language_base};

use super::{Callbacks, Command, SystemVoice};

const COMMON_VARIANTS: &[&str] = &["female1", "female2", "male1", "male2"];
const RESPONSE_TIMEOUT: Duration = Duration::from_secs(3);

struct Playback {
    generation: u64,
    sentences: VecDeque<Sentence>,
    bases: VecDeque<u32>,
    base: u32,
    current_message: Option<u32>,
}

pub fn start(callbacks: Callbacks) -> Sender<Command> {
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || run(receiver, callbacks));
    sender
}

fn run(receiver: Receiver<Command>, callbacks: Callbacks) {
    let (mut client, voices, ssml) = match initialize() {
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
                Command::Play {
                    generation,
                    plan,
                    sentence_bases,
                } => {
                    cancel(&mut client);
                    playback = Some(Playback {
                        generation,
                        sentences: plan.sentences.into(),
                        bases: sentence_bases.into(),
                        base: 0,
                        current_message: None,
                    });
                    speak_next(&mut client, &voices, ssml, &mut playback, &callbacks);
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
            Ok(Response::EventIndexMark(event, mark)) => {
                report_mark(&event, &mark, &playback, &callbacks);
            }
            Ok(Response::EventEnd(event)) => {
                let message_id = event.message.parse::<u32>().ok();
                if playback.as_ref().and_then(|item| item.current_message) == message_id {
                    speak_next(&mut client, &voices, ssml, &mut playback, &callbacks);
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

fn initialize() -> Result<(Client<UnixStream>, Vec<SynthesisVoice>, bool), String> {
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

    // SSML mode lets Flow embed index marks before every word; when the
    // server refuses it, playback still works but without word highlights.
    let ssml = client
        .set_ssml_mode(true)
        .map(|client| expect(client, |response| matches!(response, Response::SsmlModeSet)))
        .is_ok();

    Ok((client, voices, ssml))
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
    ssml: bool,
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
    active.base = active.bases.pop_front().unwrap_or(0);

    match configure(client, voices, &sentence).and_then(|()| speak(client, &sentence.text, ssml)) {
        Ok(message_id) => {
            active.current_message = Some(message_id);
            // Always report the sentence range so the popup can show reading
            // position; modules with SSML support refine it to word level
            // through index marks.
            let start = active.base;
            let end = start + sentence.text.encode_utf16().count() as u32;
            (callbacks.word_range)((active.generation, start, end));
        }
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

fn speak(client: &mut Client<UnixStream>, text: &str, ssml: bool) -> Result<u32, String> {
    client.speak().map_err(client_error)?;
    expect(client, |response| {
        matches!(response, Response::ReceivingData)
    })?;
    let normalized = text
        .replace('\0', " ")
        .lines()
        .collect::<Vec<_>>()
        .join(" ");
    let payload = if ssml {
        ssml_with_word_marks(&normalized)
    } else {
        normalized
    };
    client.send_line(&payload).map_err(client_error)?;
    receive_message_id(client)
}

/// Wraps the sentence in SSML with an index mark before every word so Speech
/// Dispatcher reports progress. Offsets are UTF-16 units, matching QML string
/// indexing and the cloud word timings.
fn ssml_with_word_marks(text: &str) -> String {
    use unicode_segmentation::UnicodeSegmentation;

    let mut payload = String::from("<speak>");
    let mut offset = 0usize;
    for piece in text.split_word_bounds() {
        let end = offset + piece.encode_utf16().count();
        if piece.chars().any(char::is_alphanumeric) {
            payload.push_str(&format!("<mark name=\"{offset}:{end}\"/>"));
        }
        payload.push_str(&escape_ssml(piece));
        offset = end;
    }
    payload.push_str("</speak>");
    payload
}

fn escape_ssml(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn parse_mark(mark: &str) -> Option<(u32, u32)> {
    let (start, end) = mark.split_once(':')?;
    Some((start.parse().ok()?, end.parse().ok()?))
}

fn report_mark(
    event: &ssip_client_async::EventId,
    mark: &str,
    playback: &Option<Playback>,
    callbacks: &Callbacks,
) {
    let Some(active) = playback else {
        return;
    };
    let Some(message_id) = active.current_message else {
        return;
    };
    if event.message.parse::<u32>().ok() != Some(message_id) {
        return;
    }
    let Some((start, end)) = parse_mark(mark) else {
        return;
    };
    (callbacks.word_range)((active.generation, active.base + start, active.base + end));
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

    #[test]
    fn ssml_marks_use_utf16_offsets_and_escape_markup() {
        // Word bounds: ["a", " ", "<", "b", ">", " ", "é"]; only word-like
        // pieces get marks and markup characters are escaped.
        assert_eq!(
            ssml_with_word_marks("a <b> é"),
            "<speak><mark name=\"0:1\"/>a &lt;<mark name=\"3:4\"/>b&gt; <mark name=\"6:7\"/>é</speak>"
        );
    }

    #[test]
    fn parse_mark_reads_offsets() {
        assert_eq!(parse_mark("12:17"), Some((12, 17)));
        assert_eq!(parse_mark("x:17"), None);
        assert_eq!(parse_mark("12"), None);
    }

    /// Live round-trip against Speech Dispatcher: speaking with SSML marks
    /// must deliver word ranges. Needs speech-dispatcher plus an output
    /// module and audio device, so run it explicitly:
    /// cargo test -p flow-desktop -- --ignored --nocapture
    #[test]
    #[ignore = "requires a working Speech Dispatcher and audio device"]
    fn dispatcher_reports_word_ranges_for_ssml_marks() {
        use flow_core::{language, model::Settings};
        use std::sync::{Arc, Mutex};

        let (start_tx, start_rx) = std::sync::mpsc::channel();
        let ranges: Arc<Mutex<Vec<(u32, u32)>>> = Arc::new(Mutex::new(Vec::new()));
        let observed = Arc::clone(&ranges);
        let commands = start(Callbacks {
            voices_changed: Box::new(|_| {}),
            finished: Box::new(move |_| {
                let _ = start_tx.send(());
            }),
            failed: Box::new(|(generation, message)| {
                panic!("system speech failed ({generation}): {message}");
            }),
            word_range: Box::new(move |(_, start, end)| {
                observed.lock().unwrap().push((start, end));
            }),
        });

        let settings = Settings::default();
        let text = "Flow highlights every spoken word";
        let plan = language::single_sentence(text, &settings);
        commands
            .send(Command::Play {
                generation: 1,
                plan,
                sentence_bases: vec![0],
            })
            .unwrap();

        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            if start_rx.recv_timeout(Duration::from_millis(500)).is_ok() {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "playback did not finish within 30 seconds"
            );
        }
        commands.send(Command::Stop).unwrap();

        let seen = ranges.lock().unwrap().clone();
        println!("received word ranges: {seen:?}");
        // The sentence range is always reported; modules with SSML support add
        // per-word index marks on top.
        assert!(
            seen.contains(&(0, text.encode_utf16().count() as u32)),
            "expected the sentence range, got {seen:?}"
        );
        assert!(seen.windows(2).all(|pair| pair[0].0 <= pair[1].0));
    }
}
