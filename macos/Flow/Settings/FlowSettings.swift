import AVFoundation
import Carbon
import Foundation

struct FlowSettings: Codable, Equatable {
    static let storageKey = "io.github.jdreioe.flow.settings"
    static let maximumSelectionCharacters = 45_000

    enum SameSelectionAction: String, Codable, CaseIterable, Identifiable {
        case pauseResume
        case restart

        var id: String { rawValue }
        var title: String {
            switch self {
            case .pauseResume: "Pause or resume"
            case .restart: "Restart reading"
            }
        }
    }

    enum SpeechSource: String, Codable, CaseIterable, Identifiable {
        case system
        case azure
        case google

        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "System voice"
            case .azure: "Azure voice"
            case .google: "Google Cloud voice"
            }
        }
    }

    struct LanguageRoute: Codable, Equatable, Identifiable {
        let id: UUID
        var languageTag: String
        var systemVoiceIdentifier: String?
        var systemSpeechRate: Float
        var azureVoiceName: String?
        var azureSpeechRate: Float
        var googleVoiceName: String?
        var googleSpeechRate: Float
        var playbackSpeed: Float?

        init(
            id: UUID = UUID(),
            languageTag: String,
            systemVoiceIdentifier: String? = nil,
            systemSpeechRate: Float = AVSpeechUtteranceDefaultSpeechRate,
            azureVoiceName: String? = nil,
            azureSpeechRate: Float = AVSpeechUtteranceDefaultSpeechRate,
            googleVoiceName: String? = nil,
            googleSpeechRate: Float = AVSpeechUtteranceDefaultSpeechRate,
            playbackSpeed: Float? = nil,
        ) {
            self.id = id
            self.languageTag = languageTag
            self.systemVoiceIdentifier = systemVoiceIdentifier
            self.systemSpeechRate = systemSpeechRate
            self.azureVoiceName = azureVoiceName
            self.azureSpeechRate = azureSpeechRate
            self.googleVoiceName = googleVoiceName
            self.googleSpeechRate = googleSpeechRate
            self.playbackSpeed = playbackSpeed
        }

        private enum CodingKeys: String, CodingKey {
            case id, languageTag, systemVoiceIdentifier, systemSpeechRate
            case azureVoiceName, azureSpeechRate, googleVoiceName, googleSpeechRate
            case playbackSpeed
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            languageTag = try values.decode(String.self, forKey: .languageTag)
            systemVoiceIdentifier = try values.decodeIfPresent(String.self, forKey: .systemVoiceIdentifier)
            systemSpeechRate = try values.decode(Float.self, forKey: .systemSpeechRate)
            azureVoiceName = try values.decodeIfPresent(String.self, forKey: .azureVoiceName)
            azureSpeechRate = try values.decode(Float.self, forKey: .azureSpeechRate)
            googleVoiceName = try values.decodeIfPresent(String.self, forKey: .googleVoiceName)
            googleSpeechRate = try values.decodeIfPresent(Float.self, forKey: .googleSpeechRate)
                ?? AVSpeechUtteranceDefaultSpeechRate
            if let speed = try values.decodeIfPresent(Float.self, forKey: .playbackSpeed) {
                playbackSpeed = min(max(speed, 0.5), 4)
            } else {
                playbackSpeed = nil
            }
        }

        func effectivePlaybackSpeed(default global: Float) -> Float {
            min(max(playbackSpeed ?? global, 0.5), 4)
        }

        var displayName: String {
            Locale.current.localizedString(forIdentifier: languageTag) ?? languageTag
        }
    }

    enum AzureVoiceMode: String, Codable, CaseIterable, Identifiable {
        case multilingual
        case perLanguage

        var id: String { rawValue }
        var title: String { self == .multilingual ? "One multilingual voice" : "A voice per language" }
    }

    var speechSource: SpeechSource = .system
    var hotKey: HotKeyPreset = .optionCommandR
    var voiceIdentifier: String?
    var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate
    var popupDismissSeconds: Double = 8
    var sameSelectionAction: SameSelectionAction = .pauseResume
    var wordHighlightingEnabled = false
    var azureVoiceName = "en-US-AvaMultilingualNeural"
    var azureSpeechRate: Float = AVSpeechUtteranceDefaultSpeechRate
    var azureVoiceMode: AzureVoiceMode = .multilingual
    var googleVoiceName: String?
    var googleSpeechRate: Float = AVSpeechUtteranceDefaultSpeechRate
    var playbackSpeed: Float = 1
    var defaultLanguageTag = "en-US"
    var languageSwitchingEnabled = true
    var languageRoutes: [LanguageRoute] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case speechSource, hotKey, voiceIdentifier, speechRate, popupDismissSeconds, sameSelectionAction, wordHighlightingEnabled
        case azureVoiceName, azureSpeechRate, azureVoiceMode
        case googleVoiceName, googleSpeechRate
        case playbackSpeed
        case defaultLanguageTag, languageSwitchingEnabled, languageRoutes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Older experimental settings stored a removed Siri source. Treat it
        // as the normal on-device source rather than discarding all settings.
        speechSource = (try? values.decodeIfPresent(SpeechSource.self, forKey: .speechSource)) ?? .system
        hotKey = try values.decodeIfPresent(HotKeyPreset.self, forKey: .hotKey) ?? .optionCommandR
        voiceIdentifier = try values.decodeIfPresent(String.self, forKey: .voiceIdentifier)
        speechRate = try values.decodeIfPresent(Float.self, forKey: .speechRate) ?? AVSpeechUtteranceDefaultSpeechRate
        popupDismissSeconds = try values.decodeIfPresent(Double.self, forKey: .popupDismissSeconds) ?? 8
        sameSelectionAction = try values.decodeIfPresent(SameSelectionAction.self, forKey: .sameSelectionAction) ?? .pauseResume
        wordHighlightingEnabled = try values.decodeIfPresent(Bool.self, forKey: .wordHighlightingEnabled) ?? false
        azureVoiceName = try values.decodeIfPresent(String.self, forKey: .azureVoiceName) ?? "en-US-AvaMultilingualNeural"
        azureSpeechRate = try values.decodeIfPresent(Float.self, forKey: .azureSpeechRate) ?? AVSpeechUtteranceDefaultSpeechRate
        azureVoiceMode = try values.decodeIfPresent(AzureVoiceMode.self, forKey: .azureVoiceMode) ?? .multilingual
        googleVoiceName = try values.decodeIfPresent(String.self, forKey: .googleVoiceName)
        googleSpeechRate = try values.decodeIfPresent(Float.self, forKey: .googleSpeechRate) ?? AVSpeechUtteranceDefaultSpeechRate
        playbackSpeed = min(max(try values.decodeIfPresent(Float.self, forKey: .playbackSpeed) ?? 1, 0.5), 4)
        defaultLanguageTag = try values.decodeIfPresent(String.self, forKey: .defaultLanguageTag) ?? "en-US"
        languageSwitchingEnabled = try values.decodeIfPresent(Bool.self, forKey: .languageSwitchingEnabled) ?? true
        languageRoutes = try values.decodeIfPresent([LanguageRoute].self, forKey: .languageRoutes) ?? []
    }

    var defaultLanguageRoute: LanguageRoute {
        LanguageRoute(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            languageTag: defaultLanguageTag,
            systemVoiceIdentifier: voiceIdentifier,
            systemSpeechRate: speechRate,
            azureVoiceName: azureVoiceName,
            azureSpeechRate: azureSpeechRate,
            googleVoiceName: googleVoiceName,
            googleSpeechRate: googleSpeechRate,
        )
    }

    var allLanguageRoutes: [LanguageRoute] { [defaultLanguageRoute] + languageRoutes }

    func languageRoute(for detectedTag: String) -> LanguageRoute? {
        let base = detectedTag.split(separator: "-").first?.lowercased()
        return allLanguageRoutes.first { route in
            route.languageTag.lowercased() == detectedTag.lowercased() ||
                route.languageTag.split(separator: "-").first?.lowercased() == base
        }
    }

    mutating func ensureExplicitSystemVoices() {
        if voiceIdentifier == nil || voiceIdentifier?.contains(".siri.") == true {
            voiceIdentifier = SystemSpeechEngine.defaultVoice(for: defaultLanguageTag)?.identifier
        }
        for index in languageRoutes.indices {
            if languageRoutes[index].systemVoiceIdentifier == nil || languageRoutes[index].systemVoiceIdentifier?.contains(".siri.") == true {
                languageRoutes[index].systemVoiceIdentifier = SystemSpeechEngine.defaultVoice(for: languageRoutes[index].languageTag)?.identifier
            }
        }
    }

    static func load() -> FlowSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(FlowSettings.self, from: data) else {
            return FlowSettings()
        }
        return settings
    }
}

enum HotKeyPreset: String, Codable, CaseIterable, Identifiable {
    case optionCommandR
    case optionCommandSpace
    case controlOptionR

    var id: String { rawValue }
    var title: String {
        switch self {
        case .optionCommandR: "Option-Command-R"
        case .optionCommandSpace: "Option-Command-Space"
        case .controlOptionR: "Control-Option-R"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .optionCommandR, .controlOptionR: UInt32(kVK_ANSI_R)
        case .optionCommandSpace: UInt32(kVK_Space)
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .optionCommandR, .optionCommandSpace: UInt32(optionKey | cmdKey)
        case .controlOptionR: UInt32(optionKey | controlKey)
        }
    }
}
