//! Flow desktop: one iced UI over the shared playback controller.
//!
//! Linux and Windows share every module here; only selection capture, global
//! shortcuts, system speech, updates, and the tray icon's OS details differ,
//! each behind a small platform module.

#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

mod audio;
mod azure;
mod controller;
mod google;
mod piper;
mod selection;
mod settings;
mod shortcuts;
mod system_speech;
mod updates;

use std::collections::HashSet;

use controller::{Controller, Event, PlaybackState};
use flow_core::{
    language,
    model::{HotKeyPreset, SameSelectionAction, Settings, SpeechSource},
};
use iced::{
    Element, Font, Length, Task,
    font::Weight,
    futures::Stream,
    widget::{
        button, checkbox, column, container, pick_list, rich_text, row, rule, scrollable,
        slider, space, span, text, text_input,
    },
};
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel};
use uuid::Uuid;

fn main() -> iced::Result {
    #[cfg(target_os = "windows")]
    velopack::VelopackApp::build().run();

    #[cfg(target_os = "linux")]
    controller_linux_theme_icons();

    iced::application(Flow::new, Flow::update, Flow::view)
        .title(title)
        .window(iced::window::Settings {
            size: iced::Size::new(520.0, 680.0),
            ..Default::default()
        })
        .run()
}

#[derive(Debug, Clone)]
pub enum Message {
    Worker(Event),
    ReadSelection,
    PauseResume,
    Stop,
    TestVoice,
    ShowSettings(bool),
    CheckUpdates,
    RestartUpdate,
    SetOverride(Option<String>),
    SetRouteForDetected { tag: String, route: Uuid },
    SetOverrideRoute(Uuid),
    ApplySetting { key: &'static str, value: String },
    Speed(f64),
    AddLanguage(String),
    RemoveLanguage(Uuid),
    ApplyRoute { route: Uuid, field: &'static str, value: String },
    AzureEndpointChanged(String),
    AzureKeyChanged(String),
    AzureSave,
    AzureClear,
    GoogleKeyChanged(String),
    GoogleSave,
    GoogleClear,
    PiperRefresh,
    PiperDownload(String),
    PiperPreview(String),
    PiperDelete(String),
    ToggleLanguages,
    ToggleRoute(Uuid),
    LanguageToAdd(String),
    SpeedPreview(f64),
    SpeedCommit,
    DismissStep(i32),
    TrayRead,
    TraySettings,
    TrayCheckUpdates,
    TrayQuit,
}

fn title(_: &Flow) -> String {
    "Flow".into()
}

struct Flow {
    controller: Controller,
    audio: audio::Player,
    show_settings: bool,
    show_languages: bool,
    expanded_routes: HashSet<Uuid>,
    language_to_add: String,
    pending_speed: Option<f64>,
    azure_endpoint: String,
    azure_key: String,
    google_key: String,
}

impl Flow {
    fn new() -> (Self, Task<Message>) {
        let (tx, rx): (UnboundedSender<Message>, UnboundedReceiver<Message>) = unbounded_channel();
        let mut controller = Controller::new(tx.clone());
        controller.start_services();
        #[cfg(feature = "tray")]
        tray::spawn(tx);
        (
            Self {
                controller,
                audio: audio::Player::new(),
                show_settings: false,
                show_languages: false,
                expanded_routes: HashSet::new(),
                language_to_add: "da-DK".into(),
                pending_speed: None,
                azure_endpoint: String::new(),
                azure_key: String::new(),
                google_key: String::new(),
            },
            Task::stream(InboxStream { rx }),
        )
    }

    fn update(&mut self, message: Message) -> Task<Message> {
        match message {
            Message::Worker(event) => self.controller.apply(&mut self.audio, event),
            Message::ReadSelection => self.controller.request_selection(),
            Message::PauseResume => self.controller.toggle_pause(&mut self.audio),
            Message::Stop => self.controller.stop_reading(&mut self.audio),
            Message::TestVoice => self.controller.play_test_voice(&mut self.audio),
            Message::ShowSettings(show) => self.show_settings = show,
            Message::CheckUpdates => self.controller.start_update_check(true),
            Message::RestartUpdate => self.controller.restart_to_update(),
            Message::SetOverride(tag) => self
                .controller
                .set_text_language_override(&mut self.audio, tag),
            Message::SetRouteForDetected { tag, route } => self
                .controller
                .set_route_for_language(&mut self.audio, &tag, route),
            Message::SetOverrideRoute(route) => self
                .controller
                .set_override_route(&mut self.audio, route),
            Message::ApplySetting { key, value } => self.controller.apply_setting(key, &value),
            Message::Speed(speed) => self.controller.set_playback_speed(&mut self.audio, speed),
            Message::AddLanguage(tag) => self.controller.add_language_route(&tag),
            Message::RemoveLanguage(route) => self.controller.remove_language_route(route),
            Message::ApplyRoute { route, field, value } => {
                self.controller.apply_route_setting(route, field, &value);
            }
            Message::AzureEndpointChanged(value) => self.azure_endpoint = value,
            Message::AzureKeyChanged(value) => self.azure_key = value,
            Message::AzureSave => {
                let endpoint = std::mem::take(&mut self.azure_endpoint);
                let key = std::mem::take(&mut self.azure_key);
                self.controller.save_azure(&endpoint, &key);
            }
            Message::AzureClear => self.controller.clear_azure(),
            Message::GoogleKeyChanged(value) => self.google_key = value,
            Message::GoogleSave => {
                let key = std::mem::take(&mut self.google_key);
                self.controller.save_google(&key);
            }
            Message::GoogleClear => self.controller.clear_google(),
            Message::PiperRefresh => self.controller.load_piper_catalog(),
            Message::PiperDownload(key) => self.controller.start_piper_download(&key),
            Message::PiperPreview(key) => self.controller.preview_piper_voice(&mut self.audio, &key),
            Message::PiperDelete(key) => self.controller.delete_piper_voice(&key),
            Message::ToggleLanguages => self.show_languages = !self.show_languages,
            Message::ToggleRoute(route) => {
                if !self.expanded_routes.remove(&route) {
                    self.expanded_routes.insert(route);
                }
            }
            Message::LanguageToAdd(tag) => self.language_to_add = tag,
            Message::SpeedPreview(speed) => self.pending_speed = Some(speed),
            Message::SpeedCommit => {
                if let Some(speed) = self.pending_speed.take() {
                    self.controller.set_playback_speed(&mut self.audio, speed);
                }
            }
            Message::DismissStep(delta) => {
                let next = (self.controller.settings.popup_dismiss_seconds + delta as f64)
                    .clamp(3.0, 30.0);
                self.controller
                    .apply_setting("popupDismissSeconds", &next.to_string());
            }
            Message::TrayRead => self.controller.request_selection(),
            Message::TraySettings => self.show_settings = true,
            Message::TrayCheckUpdates => self.controller.start_update_check(true),
            Message::TrayQuit => return iced::exit(),
        }
        Task::none()
    }

    fn view(&self) -> Element<'_, Message> {
        let content: Element<'_, Message> = if self.show_settings {
            self.settings_view()
        } else {
            self.playback_view()
        };
        container(scrollable(content).height(Length::Fill))
            .padding(16)
            .into()
    }

    /// Playback popup mirroring the macOS presentation: title header with
    /// override and stop controls, language check, highlighted text, speed,
    /// and transport. The window doubles as the app entry point where no
    /// tray runs, so it keeps a compact launcher row at the bottom.
    fn playback_view(&self) -> Element<'_, Message> {
        let c = &self.controller;
        let mut header: Vec<Element<'_, Message>> = vec![
            text(c.playback_state.title()).size(20).into(),
        ];
        if c.playback_state == PlaybackState::Preparing {
            header.push(text("Preparing…").size(12).into());
        }
        header.push(space::horizontal().into());
        if shows_override(c) {
            header.push(override_picker(c));
        }
        if matches!(
            c.playback_state,
            PlaybackState::Playing | PlaybackState::Paused
        ) {
            header.push(
                button(if self.show_languages {
                    "Hide languages"
                } else {
                    "Language…"
                })
                .on_press(Message::ToggleLanguages)
                .into(),
            );
        }
        header.push(button("Stop").on_press(Message::Stop).into());

        let mut items: Vec<Element<'_, Message>> = vec![
            row(header).spacing(8).align_y(iced::Alignment::Center).into(),
            row![
                text(&c.shortcut_status).size(12),
                space::horizontal(),
                button("Settings").on_press(Message::ShowSettings(true)),
            ]
            .align_y(iced::Alignment::Center)
            .into(),
        ];

        match c.playback_state {
            PlaybackState::Hidden => {
                items.push(
                    text("Select some text, then press your shortcut or Read selection.")
                        .into(),
                );
            }
            PlaybackState::Message | PlaybackState::Finished => {
                if !c.message.is_empty() {
                    items.push(text(&c.message).into());
                } else {
                    items.push(text("Finished reading.").into());
                }
            }
            _ => {
                items.push(
                    scrollable(highlighted_text(c))
                        .height(160)
                        .into(),
                );
            }
        }

        if (c.language_override.is_some() && c.override_needs_route)
            || c.manual_route_needed
        {
            if c.manual_route_needed && !c.manual_route_sentence_text.is_empty() {
                items.push(text(format!("“{}”", c.manual_route_sentence_text)).into());
            }
            items.push(
                route_picker_unselected(c, Message::SetOverrideRoute, "Read as…"),
            );
            if c.playback_state == PlaybackState::AwaitingRoute {
                items.push(
                    text(if c.manual_route_needed {
                        "Choose how Flow should read this sentence before playback starts."
                    } else {
                        "Choose how Flow should read this selection before playback starts."
                    })
                    .size(12)
                    .into(),
                );
            }
        }

        if self.show_languages && !c.detected_languages.is_empty() {
            for tag in &c.detected_languages {
                items.push(
                    row![
                        text(tag),
                        route_picker(
                            c,
                            Some(tag),
                            move |route| Message::SetRouteForDetected {
                                tag: tag.clone(),
                                route,
                            },
                        ),
                    ]
                    .spacing(8)
                    .align_y(iced::Alignment::Center)
                    .into(),
                );
            }
        }

        if shows_speed(c) {
            let speed = self.pending_speed.unwrap_or(c.playback_speed);
            items.push(
                row![
                    text("0.5×").size(11),
                    slider(0.5..=4.0, speed, Message::SpeedPreview)
                        .step(0.25)
                        .width(Length::Fill)
                        .on_release(Message::SpeedCommit),
                    text("4×").size(11),
                    text(speed_label(speed)).width(48),
                ]
                .spacing(8)
                .align_y(iced::Alignment::Center)
                .into(),
            );
        }

        if matches!(
            c.playback_state,
            PlaybackState::Playing | PlaybackState::Paused
        ) {
            items.push(
                button(if c.playback_state == PlaybackState::Paused {
                    "Resume"
                } else {
                    "Pause"
                })
                .on_press(Message::PauseResume)
                .into(),
            );
        }

        if !c.update_ready_version.is_empty() {
            items.push(
                row![
                    text(format!("Flow {} is downloaded.", c.update_ready_version)),
                    button("Restart to update").on_press(Message::RestartUpdate),
                ]
                .spacing(8)
                .into(),
            );
        }

        items.push(rule::horizontal(8).into());
        items.push(
            row![
                button("Read selected text").on_press(Message::ReadSelection),
                button("Test voice").on_press(Message::TestVoice),
            ]
            .spacing(8)
            .into(),
        );

        iced::widget::Column::with_children(items)
            .spacing(10)
            .into()
    }

    /// Settings grouped like the macOS form: Access, Language Flow, Speech,
    /// Playback, Privacy. Piper has no macOS counterpart and gets its own
    /// "Offline voices" section after Speech.
    fn settings_view(&self) -> Element<'_, Message> {
        let settings = &self.controller.settings;
        let mut items: Vec<Element<'_, Message>> = vec![
            row![
                text("Flow settings").size(20),
                space::horizontal(),
                button("Back").on_press(Message::ShowSettings(false)),
            ]
            .align_y(iced::Alignment::Center)
            .into(),
        ];

        if !self.controller.configuration_error.is_empty() {
            items.push(text(&self.controller.configuration_error).into());
        }

        items.push(section_title("Access"));
        items.push(hotkey_row(settings));
        items.push(
            text("Flow reads only the selection your desktop's accessibility exposes when you trigger it.")
                .size(12)
                .into(),
        );

        items.push(section_title("Language Flow"));
        items.push(
            row![
                text("0.5×").size(11),
                slider(0.5..=4.0, settings.playback_speed, Message::Speed)
                    .step(0.25)
                    .width(Length::Fill),
                text("4×").size(11),
                text(speed_label(settings.playback_speed)).width(48),
            ]
            .spacing(8)
            .align_y(iced::Alignment::Center)
            .into(),
        );
        items.push(text("Fallback voice").size(14).into());
        items.push(source_route_editor(
            &self.controller,
            flow_core::model::DEFAULT_LANGUAGE_ROUTE_ID,
            true,
        ));
        for route in &self.controller.settings.language_routes {
            items.push(route_row(self, route));
        }
        items.push(add_language_row(self));

        items.push(section_title("Speech"));
        items.push(
            pick_list(
                [
                    SourceChoice(SpeechSource::System),
                    SourceChoice(SpeechSource::Azure),
                    SourceChoice(SpeechSource::Google),
                    SourceChoice(SpeechSource::Piper),
                ],
                Some(SourceChoice(settings.speech_source)),
                |source| Message::ApplySetting {
                    key: "speechSource",
                    value: source.key().into(),
                },
            )
            .placeholder("Choose a speech source")
            .into(),
        );
        items.push(speech_configuration(self));

        items.push(section_title("Offline voices (Piper)"));
        items.push(piper_editor(&self.controller));

        items.push(section_title("Playback"));
        items.push(
            button("Play test voice")
                .on_press(Message::TestVoice)
                .into(),
        );
        items.push(
            row![
                text("Same selection"),
                pick_list(
                    [
                        ActionChoice(SameSelectionAction::PauseResume),
                        ActionChoice(SameSelectionAction::Restart),
                    ],
                    Some(ActionChoice(settings.same_selection_action)),
                    |action| Message::ApplySetting {
                        key: "sameSelectionAction",
                        value: action.key().into(),
                    },
                )
                .placeholder("Choose behavior"),
            ]
            .spacing(8)
            .align_y(iced::Alignment::Center)
            .into(),
        );
        if settings.speech_source != SpeechSource::Azure {
            items.push(
                checkbox(settings.word_highlighting_enabled)
                    .label("Highlight spoken words")
                    .on_toggle(|enabled| Message::ApplySetting {
                        key: "wordHighlightingEnabled",
                        value: enabled.to_string(),
                    })
                    .into(),
            );
        }
        items.push(
            row![
                button("−").on_press(Message::DismissStep(-1)),
                text(format!(
                    "Popup dismisses after {} seconds",
                    settings.popup_dismiss_seconds as i32
                )),
                button("+").on_press(Message::DismissStep(1)),
            ]
            .spacing(8)
            .align_y(iced::Alignment::Center)
            .into(),
        );
        items.push(
            text("Selections longer than about ten minutes are not read.")
                .size(12)
                .into(),
        );

        items.push(section_title("Privacy"));
        items.push(
            text("Flow keeps selected text only while reading. Language detection and system voices stay on-device. A cloud provider receives text only when that provider is selected.")
                .size(12)
                .into(),
        );

        items.push(rule::horizontal(8).into());
        items.push(
            row![
                button("Check for updates").on_press(Message::CheckUpdates),
                button("Test voice").on_press(Message::TestVoice),
            ]
            .spacing(8)
            .into(),
        );
        items.push(text(format!("Flow {}", updates::VERSION)).size(12).into());

        iced::widget::Column::with_children(items)
            .spacing(10)
            .into()
    }
}

fn section_title(title: &str) -> Element<'_, Message> {
    text(title).size(16).into()
}

fn shows_override(c: &Controller) -> bool {
    matches!(
        c.playback_state,
        PlaybackState::Preparing
            | PlaybackState::Playing
            | PlaybackState::Paused
            | PlaybackState::AwaitingRoute
    )
}

fn shows_speed(c: &Controller) -> bool {
    shows_override(c)
}

fn override_picker(c: &Controller) -> Element<'_, Message> {
    let languages: Vec<String> = language::supported_languages()
        .iter()
        .map(|(tag, _)| tag.to_string())
        .collect();
    row![
        text("Read in").size(12),
        pick_list(languages, c.language_override.clone(), |tag| {
            Message::SetOverride(Some(tag))
        })
        .placeholder("Auto"),
        button("Auto").on_press(Message::SetOverride(None)),
    ]
    .spacing(6)
    .align_y(iced::Alignment::Center)
    .into()
}

/// Selected text with the spoken word tinted, like the macOS popup: already
/// read text recedes, the active word stands out, the rest stays primary.
fn highlighted_text(c: &Controller) -> Element<'_, Message> {
    let text16: Vec<u16> = c.playback_text.encode_utf16().collect();
    let start = (c.current_word_start.max(0) as usize).min(text16.len());
    let end = (c.current_word_end.max(0) as usize)
        .min(text16.len())
        .max(start);
    if start >= end
        || String::from_utf16_lossy(&text16[start..end])
            .trim()
            .is_empty()
    {
        return text(&c.playback_text).into();
    }
    let prefix = String::from_utf16_lossy(&text16[..start]);
    let word = String::from_utf16_lossy(&text16[start..end]);
    let suffix = String::from_utf16_lossy(&text16[end..]);
    rich_text![
        span::<(), _>(prefix).color(iced::color!(0x8e8e93)),
        span::<(), _>(word)
            .color(iced::color!(0x0a84ff))
            .font(Font {
                weight: Weight::Bold,
                ..Font::default()
            }),
        span::<(), _>(suffix),
    ]
    .into()
}

fn speed_label(speed: f64) -> String {
    if speed.fract() == 0.0 {
        format!("{speed:.0}×")
    } else {
        format!("{speed}×")
    }
}

fn route_picker<'a>(
    c: &'a Controller,
    for_language: Option<&str>,
    on_select: impl Fn(Uuid) -> Message + 'a,
) -> Element<'a, Message> {
    let routes: Vec<RouteChoice> = c
        .settings
        .all_language_routes()
        .iter()
        .map(|route| RouteChoice {
            id: route.id,
            label: route_label(c, route.id, &route.language_tag),
        })
        .collect();
    let selected = for_language
        .and_then(|tag| c.settings.language_route(tag))
        .or_else(|| {
            c.plan.as_ref().and_then(|plan| {
                plan.sentences
                    .iter()
                    .find(|sentence| sentence.needs_review)
                    .map(|sentence| sentence.route.clone())
            })
        })
        .map(|route| RouteChoice {
            id: route.id,
            label: route_label(c, route.id, &route.language_tag),
        });
    pick_list(routes, selected, move |choice| on_select(choice.id))
        .placeholder("Choose a voice")
        .into()
}

/// Route picker with no pre-selection, mirroring the macOS "Read as…"
/// picker that applies the chosen route the moment it is picked.
fn route_picker_unselected<'a>(
    c: &'a Controller,
    on_select: impl Fn(Uuid) -> Message + 'a,
    placeholder: &'static str,
) -> Element<'a, Message> {
    let routes: Vec<RouteChoice> = c
        .settings
        .all_language_routes()
        .iter()
        .map(|route| RouteChoice {
            id: route.id,
            label: route_label(c, route.id, &route.language_tag),
        })
        .collect();
    pick_list(routes, None::<RouteChoice>, move |choice| on_select(choice.id))
        .placeholder(placeholder)
        .into()
}

fn route_label(c: &Controller, id: Uuid, tag: &str) -> String {
    if id == flow_core::model::DEFAULT_LANGUAGE_ROUTE_ID {
        format!("{tag} (default: {})", c.settings.default_language_tag)
    } else {
        tag.to_owned()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct SourceChoice(SpeechSource);

impl std::fmt::Display for SourceChoice {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self.0 {
            SpeechSource::System => "System voices",
            SpeechSource::Azure => "Azure Speech",
            SpeechSource::Google => "Google Cloud",
            SpeechSource::Piper => "Piper (offline)",
        })
    }
}

impl SourceChoice {
    fn key(self) -> &'static str {
        match self.0 {
            SpeechSource::System => "system",
            SpeechSource::Azure => "azure",
            SpeechSource::Google => "google",
            SpeechSource::Piper => "piper",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct HotKeyChoice(HotKeyPreset);

impl std::fmt::Display for HotKeyChoice {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0.title())
    }
}

impl HotKeyChoice {
    fn key(self) -> &'static str {
        match self.0 {
            HotKeyPreset::AltSuperR => "altSuperR",
            HotKeyPreset::AltSuperSpace => "altSuperSpace",
            HotKeyPreset::ControlAltR => "controlAltR",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct RouteChoice {
    id: Uuid,
    label: String,
}

impl std::fmt::Display for RouteChoice {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.label)
    }
}

fn hotkey_row(settings: &Settings) -> Element<'_, Message> {
    row![
        text("Shortcut"),
        pick_list(
            [
                HotKeyChoice(HotKeyPreset::AltSuperR),
                HotKeyChoice(HotKeyPreset::AltSuperSpace),
                HotKeyChoice(HotKeyPreset::ControlAltR),
            ],
            Some(HotKeyChoice(settings.hot_key)),
            |preset| Message::ApplySetting {
                key: "hotKey",
                value: preset.key().into(),
            },
        )
        .placeholder("Choose a shortcut"),
    ]
    .spacing(8)
    .align_y(iced::Alignment::Center)
    .into()
}

/// Voice and rate editors for one route, showing only the active speech
/// source's picker like the macOS route editor. The default route edits the
/// shared settings; other routes edit their own fields plus playback speed.
fn source_route_editor(c: &Controller, route_id: Uuid, is_default: bool) -> Element<'_, Message> {
    let Some(fields) = route_fields(&c.settings, route_id) else {
        return space::vertical().height(0).into();
    };
    let mut items: Vec<Element<'_, Message>> = match c.settings.speech_source {
        SpeechSource::System => {
            let options = matching_system_voices(c, &fields.tag);
            let mut section = vec![
                voice_pick(
                    options,
                    fields.system_voice,
                    route_id,
                    "systemVoiceName",
                    "Default system voice",
                ),
            ];
            if matching_system_voices(c, &fields.tag).is_empty() {
                section.push(
                    text(format!("No installed {} voice was found.", fields.tag))
                        .size(12)
                        .into(),
                );
            }
            section.push(rate_row(fields.system_rate, route_id, "systemSpeechRate"));
            section
        }
        SpeechSource::Azure => {
            let mut section = vec![voice_pick(
                matching_azure_voices(c, &fields.tag),
                fields.azure_voice,
                route_id,
                "azureVoiceName",
                "Fallback Azure voice",
            )];
            if matching_azure_voices(c, &fields.tag).is_empty() {
                section.push(
                    text(format!(
                        "No Azure voices support {} in this resource's region.",
                        fields.tag
                    ))
                    .size(12)
                    .into(),
                );
            }
            section.push(rate_row(fields.azure_rate, route_id, "azureSpeechRate"));
            section
        }
        SpeechSource::Google => {
            let mut section = vec![voice_pick(
                matching_google_voices(c, &fields.tag),
                fields.google_voice,
                route_id,
                "googleVoiceName",
                "Google default voice",
            )];
            if matching_google_voices(c, &fields.tag).is_empty() {
                section.push(
                    text(format!(
                        "No Google voices were loaded for {}. The default voice may still be available.",
                        fields.tag
                    ))
                    .size(12)
                    .into(),
                );
            }
            section.push(rate_row(fields.google_rate, route_id, "googleSpeechRate"));
            section
        }
        SpeechSource::Piper => vec![voice_pick(
            installed_piper_keys(c, &fields.tag),
            fields.piper_voice,
            route_id,
            "piperVoiceName",
            "Default Piper voice",
        )],
    };
    if !is_default {
        let mut speeds = vec![SpeedChoice {
            label: "Same as Language Flow".into(),
            value: None,
        }];
        speeds.extend((2..=16).map(|step| {
            let speed = f64::from(step) / 4.0;
            SpeedChoice {
                label: speed_label(speed),
                value: Some(speed),
            }
        }));
        let selected = SpeedChoice {
            label: fields
                .speed
                .map_or_else(|| "Same as Language Flow".into(), speed_label),
            value: fields.speed,
        };
        items.push(
            row![
                text("Speed"),
                pick_list(speeds, Some(selected), move |choice| Message::ApplyRoute {
                    route: route_id,
                    field: "playbackSpeed",
                    value: choice.value.map(|speed| speed.to_string()).unwrap_or_default(),
                })
                .placeholder("Choose a speed"),
            ]
            .spacing(8)
            .align_y(iced::Alignment::Center)
            .into(),
        );
    }
    iced::widget::Column::with_children(items)
        .spacing(6)
        .into()
}

struct RouteFields {
    tag: String,
    system_voice: Option<String>,
    system_rate: f64,
    azure_voice: Option<String>,
    azure_rate: f64,
    google_voice: Option<String>,
    google_rate: f64,
    piper_voice: Option<String>,
    speed: Option<f64>,
}

fn route_fields(settings: &Settings, route_id: Uuid) -> Option<RouteFields> {
    if route_id == flow_core::model::DEFAULT_LANGUAGE_ROUTE_ID {
        Some(RouteFields {
            tag: settings.default_language_tag.clone(),
            system_voice: settings.system_voice_name.clone(),
            system_rate: settings.system_speech_rate,
            azure_voice: Some(settings.azure_voice_name.clone()),
            azure_rate: settings.azure_speech_rate,
            google_voice: settings.google_voice_name.clone(),
            google_rate: settings.google_speech_rate,
            piper_voice: settings.piper_voice_name.clone(),
            speed: None,
        })
    } else {
        settings
            .language_routes
            .iter()
            .find(|route| route.id == route_id)
            .map(|route| RouteFields {
                tag: route.language_tag.clone(),
                system_voice: route.system_voice_name.clone(),
                system_rate: route.system_speech_rate,
                azure_voice: route.azure_voice_name.clone(),
                azure_rate: route.azure_speech_rate,
                google_voice: route.google_voice_name.clone(),
                google_rate: route.google_speech_rate,
                piper_voice: route.piper_voice_name.clone(),
                speed: route.playback_speed,
            })
    }
}

fn voice_base(tag: &str) -> String {
    tag.split('-')
        .next()
        .unwrap_or(tag)
        .to_ascii_lowercase()
}

fn matching_system_voices(c: &Controller, tag: &str) -> Vec<String> {
    c.system_voices
        .iter()
        .filter(|voice| voice_base(&voice.language_tag) == voice_base(tag))
        .map(|voice| voice.name.clone())
        .collect()
}

fn matching_azure_voices(c: &Controller, tag: &str) -> Vec<String> {
    c.azure_voices
        .iter()
        .filter(|voice| {
            voice_base(&voice.locale) == voice_base(tag)
                || voice
                    .secondary_locales
                    .iter()
                    .any(|locale| voice_base(locale) == voice_base(tag))
        })
        .map(|voice| voice.short_name.clone())
        .collect()
}

fn matching_google_voices(c: &Controller, tag: &str) -> Vec<String> {
    c.google_voices
        .iter()
        .filter(|voice| {
            voice
                .language_codes
                .iter()
                .any(|code| voice_base(code) == voice_base(tag))
        })
        .map(|voice| voice.name.clone())
        .collect()
}

fn installed_piper_keys(c: &Controller, tag: &str) -> Vec<String> {
    c.piper_voices
        .iter()
        .filter(|voice| voice.installed && voice_base(&voice.language_code) == voice_base(tag))
        .map(|voice| voice.key.clone())
        .collect()
}

fn voice_pick<'a>(
    options: Vec<String>,
    selected: Option<String>,
    route: Uuid,
    field: &'static str,
    placeholder: &'static str,
) -> Element<'a, Message> {
    pick_list(options, selected, move |name| Message::ApplyRoute {
        route,
        field,
        value: name,
    })
    .placeholder(placeholder)
    .into()
}

fn rate_row(rate: f64, route: Uuid, field: &'static str) -> Element<'static, Message> {
    row![
        text("Rate"),
        slider(-1.0..=1.0, rate, move |value| Message::ApplyRoute {
            route,
            field,
            value: value.to_string(),
        })
        .width(160),
        text(format!("{rate:+.2}")),
    ]
    .spacing(8)
    .align_y(iced::Alignment::Center)
    .into()
}

/// Collapsible per-language editor with a one-line voice summary, like the
/// macOS route list.
fn route_row<'a>(
    flow: &'a Flow,
    route: &'a flow_core::model::LanguageRoute,
) -> Element<'a, Message> {
    let id = route.id;
    let mut items: Vec<Element<'_, Message>> = vec![
        row![
            button(column![
                text(&route.language_tag).size(15),
                text(route_summary(&flow.controller, route)).size(12),
            ])
            .on_press(Message::ToggleRoute(id))
            .style(button::text),
            space::horizontal(),
            button("Remove").on_press(Message::RemoveLanguage(id)),
        ]
        .align_y(iced::Alignment::Center)
        .into(),
    ];
    if flow.expanded_routes.contains(&id) {
        items.push(source_route_editor(&flow.controller, id, false));
    }
    iced::widget::Column::with_children(items)
        .spacing(4)
        .into()
}

fn route_summary(c: &Controller, route: &flow_core::model::LanguageRoute) -> String {
    match c.settings.speech_source {
        SpeechSource::System => route
            .system_voice_name
            .clone()
            .unwrap_or_else(|| "System default voice".into()),
        SpeechSource::Azure => route
            .azure_voice_name
            .clone()
            .unwrap_or_else(|| "Fallback Azure voice".into()),
        SpeechSource::Google => route
            .google_voice_name
            .clone()
            .unwrap_or_else(|| "Google default voice".into()),
        SpeechSource::Piper => route
            .piper_voice_name
            .clone()
            .unwrap_or_else(|| "Default Piper voice".into()),
    }
}

/// Language adder offering only languages without a route yet, like macOS.
fn add_language_row(flow: &Flow) -> Element<'_, Message> {
    let settings = &flow.controller.settings;
    let options: Vec<String> = language::supported_languages()
        .iter()
        .filter(|(tag, _)| {
            *tag != settings.default_language_tag
                && !settings
                    .language_routes
                    .iter()
                    .any(|route| route.language_tag == **tag)
        })
        .map(|(tag, _)| tag.to_string())
        .collect();
    let selected = options
        .contains(&flow.language_to_add)
        .then(|| flow.language_to_add.clone());
    row![
        pick_list(options, selected, Message::LanguageToAdd).placeholder("Language"),
        button("Add language").on_press(Message::AddLanguage(flow.language_to_add.clone())),
    ]
    .spacing(8)
    .align_y(iced::Alignment::Center)
    .into()
}

fn azure_editor(flow: &Flow) -> Element<'_, Message> {
    let c = &flow.controller;
    let mut items: Vec<Element<'_, Message>> = vec![
        text_input("Region or endpoint", &flow.azure_endpoint)
            .on_input(Message::AzureEndpointChanged)
            .into(),
        text_input("Subscription key", &flow.azure_key)
            .on_input(Message::AzureKeyChanged)
            .secure(true)
            .into(),
        row![
            button("Save Azure setup").on_press(Message::AzureSave),
            button("Clear").on_press(Message::AzureClear),
        ]
        .spacing(8)
        .into(),
    ];
    if c.settings.azure_endpoint.is_some() {
        let voices: Vec<String> = c
            .azure_voices
            .iter()
            .map(|voice| voice.short_name.clone())
            .collect();
        items.push(
            pick_list(
                voices,
                Some(c.settings.azure_voice_name.clone()),
                |name| Message::ApplySetting {
                    key: "azureVoiceName",
                    value: name,
                },
            )
            .placeholder("Azure voice")
            .into(),
        );
    }
    iced::widget::Column::with_children(items)
        .spacing(6)
        .into()
}

/// Reading-source configuration for the Speech section, mirroring macOS.
fn speech_configuration(flow: &Flow) -> Element<'_, Message> {
    let c = &flow.controller;
    match c.settings.speech_source {
        SpeechSource::System => text("System voices and language detection stay on this device.")
            .size(12)
            .into(),
        SpeechSource::Azure => azure_editor(flow),
        SpeechSource::Google => google_editor(flow),
        SpeechSource::Piper => {
            text("Piper voices run fully offline on this device. Manage them below.")
                .size(12)
                .into()
        }
    }
}

fn google_editor(flow: &Flow) -> Element<'_, Message> {
    let c = &flow.controller;
    let mut items: Vec<Element<'_, Message>> = vec![
        text_input("API key", &flow.google_key)
            .on_input(Message::GoogleKeyChanged)
            .secure(true)
            .into(),
        row![
            button("Save Google setup").on_press(Message::GoogleSave),
            button("Clear").on_press(Message::GoogleClear),
        ]
        .spacing(8)
        .into(),
    ];
    if c.settings.google_api_key_configured {
        let voices: Vec<String> = c
            .google_voices
            .iter()
            .map(|voice| voice.name.clone())
            .collect();
        items.push(
            pick_list(voices, c.settings.google_voice_name.clone(), |name| {
                Message::ApplySetting {
                    key: "googleVoiceName",
                    value: name,
                }
            })
            .placeholder("Google voice")
            .into(),
        );
    }
    iced::widget::Column::with_children(items)
        .spacing(6)
        .into()
}

fn piper_editor(c: &Controller) -> Element<'_, Message> {
    let mut items: Vec<Element<'_, Message>> = vec![
        row![
            button("Reload Piper voices").on_press(Message::PiperRefresh),
            text(&c.piper_status).size(12),
        ]
        .spacing(8)
        .align_y(iced::Alignment::Center)
        .into(),
    ];
    for voice in &c.piper_voices {
        let key = voice.key.clone();
        let preview_key = voice.key.clone();
        let delete_key = voice.key.clone();
        items.push(
            row![
                text(format!(
                    "{} · {} ({} plays)",
                    voice.language_code, voice.name, voice.quality,
                )),
                space::horizontal(),
                button(if voice.installed {
                    "Preview"
                } else {
                    "Get"
                })
                .on_press(if voice.installed {
                    Message::PiperPreview(preview_key)
                } else {
                    Message::PiperDownload(key)
                }),
                button("Remove").on_press(Message::PiperDelete(delete_key)),
            ]
            .spacing(8)
            .align_y(iced::Alignment::Center)
            .into(),
        );
    }
    iced::widget::Column::with_children(items)
        .spacing(6)
        .into()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ActionChoice(SameSelectionAction);

impl std::fmt::Display for ActionChoice {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self.0 {
            SameSelectionAction::PauseResume => "Pause / resume",
            SameSelectionAction::Restart => "Restart",
        })
    }
}

impl ActionChoice {
    fn key(self) -> &'static str {
        match self.0 {
            SameSelectionAction::PauseResume => "pauseResume",
            SameSelectionAction::Restart => "restart",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
struct SpeedChoice {
    label: String,
    value: Option<f64>,
}

impl std::fmt::Display for SpeedChoice {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.label)
    }
}

struct InboxStream {
    rx: UnboundedReceiver<Message>,
}

impl Stream for InboxStream {
    type Item = Message;

    fn poll_next(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Message>> {
        self.rx.poll_recv(cx)
    }
}

#[cfg(target_os = "linux")]
fn controller_linux_theme_icons() {
    const ICON_NAME: &str = "io.github.jdreioe.flow.png";
    const SIZES: [(&str, &str); 3] = [
        ("16", "flow-16.png"),
        ("32", "flow-32.png"),
        ("48", "flow-48.png"),
    ];
    let Some(theme_root) =
        directories::BaseDirs::new().map(|dirs| dirs.data_dir().join("icons").join("hicolor"))
    else {
        return;
    };
    for (size, file) in SIZES {
        let Some(source) = icon_source(file) else {
            continue;
        };
        let target = theme_root
            .join(format!("{size}x{size}"))
            .join("apps")
            .join(ICON_NAME);
        if target
            .parent()
            .is_none_or(|dir| std::fs::create_dir_all(dir).is_err())
            || std::fs::copy(&source, &target).is_err()
        {
            // Best effort only; a desktop-installed Flow icon may already exist.
        }
    }
}

#[cfg(target_os = "linux")]
fn icon_source(file: &str) -> Option<std::path::PathBuf> {
    std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|dir| dir.to_path_buf()))
        .into_iter()
        .flat_map(|dir| {
            vec![
                dir.join("assets").join(file),
                dir.join("..")
                    .join("..")
                    .join("desktop")
                    .join("assets")
                    .join(file),
            ]
        })
        .chain(std::iter::once(
            std::path::PathBuf::from("desktop/assets").join(file),
        ))
        .find(|path| path.is_file())
}

/// Decoded tray icon shared by both backends. Without an icon several
/// desktops hide the tray entry, so a missing icon disables the tray rather
/// than showing a blank one.
#[cfg(feature = "tray")]
fn tray_rgba() -> Option<(Vec<u8>, u32, u32)> {
    let image = image::load_from_memory(include_bytes!("../assets/flow-32.png")).ok()?;
    let rgba = image.to_rgba8();
    let (width, height) = (rgba.width(), rgba.height());
    Some((rgba.into_raw(), width, height))
}

/// Linux tray through StatusNotifier (ksni): pure Rust over D-Bus, no system
/// libraries needed. Silently absent where no watcher runs; the window and
/// the global shortcut keep working.
#[cfg(all(feature = "tray", target_os = "linux"))]
mod tray {
    use ksni::{
        Tray, TrayMethods,
        menu::{MenuItem, StandardItem},
    };

    use crate::{Message, tray_rgba};
    use tokio::sync::mpsc::UnboundedSender;

    struct FlowTray {
        tx: UnboundedSender<Message>,
    }

    impl Tray for FlowTray {
        fn id(&self) -> String {
            "io.github.jdreioe.flow".into()
        }

        fn title(&self) -> String {
            "Flow".into()
        }

        fn icon_pixmap(&self) -> Vec<ksni::Icon> {
            tray_rgba()
                .map(|(mut pixels, width, height)| {
                    assert_eq!(pixels.len() % 4, 0);
                    for pixel in pixels.chunks_exact_mut(4) {
                        pixel.rotate_right(1); // RGBA to ARGB
                    }
                    ksni::Icon {
                        width: width as i32,
                        height: height as i32,
                        data: pixels,
                    }
                })
                .into_iter()
                .collect()
        }

        fn menu(&self) -> Vec<MenuItem<Self>> {
            vec![
                StandardItem {
                    label: "Read selected text".into(),
                    activate: Box::new(|tray: &mut Self| {
                        let _ = tray.tx.send(Message::TrayRead);
                    }),
                    ..Default::default()
                }
                .into(),
                StandardItem {
                    label: "Open settings".into(),
                    activate: Box::new(|tray: &mut Self| {
                        let _ = tray.tx.send(Message::TraySettings);
                    }),
                    ..Default::default()
                }
                .into(),
                StandardItem {
                    label: "Check for Updates".into(),
                    activate: Box::new(|tray: &mut Self| {
                        let _ = tray.tx.send(Message::TrayCheckUpdates);
                    }),
                    ..Default::default()
                }
                .into(),
                StandardItem {
                    label: "Quit Flow".into(),
                    activate: Box::new(|tray: &mut Self| {
                        let _ = tray.tx.send(Message::TrayQuit);
                    }),
                    ..Default::default()
                }
                .into(),
            ]
        }
    }

    pub fn spawn(tx: UnboundedSender<Message>) {
        std::thread::spawn(move || {
            let Ok(runtime) = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            else {
                return;
            };
            runtime.block_on(async move {
                // No watcher (or no session bus) means no tray; the app
                // itself is unaffected, so errors stay silent.
                if let Ok(_handle) = (FlowTray { tx }.spawn().await) {
                    std::future::pending::<()>().await;
                }
            });
        });
    }
}

/// Windows tray through tray-icon. No extra system libraries are needed there.
#[cfg(all(feature = "tray", target_os = "windows"))]
mod tray {
    use tray_icon::menu::{Menu, MenuEvent, MenuItem};

    use crate::{Message, tray_rgba};
    use tokio::sync::mpsc::UnboundedSender;

    pub fn spawn(tx: UnboundedSender<Message>) {
        std::thread::spawn(move || {
            let read = MenuItem::new("Read selected text", true, None);
            let settings = MenuItem::new("Open settings", true, None);
            let updates = MenuItem::new("Check for Updates", true, None);
            let quit = MenuItem::new("Quit Flow", true, None);
            let menu = Menu::new();
            let _ = menu.append_items(&[&read, &settings, &updates, &quit]);

            let _tray = tray_rgba().and_then(|(rgba, width, height)| {
                tray_icon::Icon::from_rgba(rgba, width, height)
                    .ok()
                    .map(|icon| {
                        tray_icon::TrayIconBuilder::new()
                            .with_icon(icon)
                            .with_tooltip("Flow")
                            .with_menu_on_left_click(false)
                            .with_menu(Box::new(menu))
                            .build()
                    })
            });

            for event in MenuEvent::receiver().iter() {
                let message = if event.id == *read.id() {
                    Message::TrayRead
                } else if event.id == *settings.id() {
                    Message::TraySettings
                } else if event.id == *updates.id() {
                    Message::TrayCheckUpdates
                } else if event.id == *quit.id() {
                    Message::TrayQuit
                } else {
                    continue;
                };
                if tx.send(message).is_err() {
                    break;
                }
            }
        });
    }
}
