import AVFoundation
import Foundation

enum AzurePortalURLs {
    static let createSpeechResource = URL(string: "https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fjdreioe%2FFlow%2Fmain%2Finfra%2Fazure-user-f0%2Fazuredeploy.json")!
    static let speechResources = URL(string: "https://portal.azure.com/#view/HubsExtension/BrowseResource/resourceType/Microsoft.CognitiveServices%2Faccounts")!
}

enum AzureVoiceCatalog {
    struct Voice: Decodable, Identifiable, Hashable {
        let shortName: String
        let locale: String
        let secondaryLocales: [String]

        var id: String { shortName }
        var isMultilingual: Bool {
            shortName.localizedCaseInsensitiveContains("multilingual") || !secondaryLocales.isEmpty
        }

        private enum CodingKeys: String, CodingKey {
            case shortName = "ShortName"
            case locale = "Locale"
            case secondaryLocales = "SecondaryLocaleList"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            shortName = try values.decode(String.self, forKey: .shortName)
            locale = try values.decode(String.self, forKey: .locale)
            secondaryLocales = try values.decodeIfPresent([String].self, forKey: .secondaryLocales) ?? []
        }

        func supports(languageTag: String) -> Bool {
            let base = languageTag.split(separator: "-").first?.lowercased()
            return ([locale] + secondaryLocales).contains {
                $0.split(separator: "-").first?.lowercased() == base
            }
        }
    }

    static func list(credentials: AzureSpeechCredentials) async throws -> [Voice] {
        let suffix = credentials.endpoint.contains(".cognitiveservices.azure.com")
            ? "/tts/cognitiveservices/voices/list"
            : "/cognitiveservices/voices/list"
        var request = URLRequest(url: URL(string: credentials.endpoint + suffix)!)
        request.setValue(credentials.subscriptionKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("Flow", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([Voice].self, from: data)
            .sorted { $0.shortName.localizedCaseInsensitiveCompare($1.shortName) == .orderedAscending }
    }
}

final class AzureSpeechEngine: NSObject, AVAudioPlayerDelegate, FlowSpeechEngine {
    var onFinished: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onWordRange: ((Range<Int>?) -> Void)?
    private var player: AVAudioPlayer?
    private var synthesisGlobalSpeed: Float = 1
    private var synthesisTask: Task<Void, Never>?

    func read(_ plan: LanguageFlow.Plan, settings: FlowSettings) {
        stop()
        synthesisGlobalSpeed = min(max(settings.playbackSpeed, 0.5), 4)
        guard let credentials = AzureCredentialsStore.load() else {
            onFailure?("Set up Azure Speech before choosing Azure voice.")
            return
        }
        synthesisTask = Task { [weak self] in
            do {
                let audio = try await Self.synthesize(plan: plan, settings: settings, credentials: credentials)
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.play(audio) }
            } catch is CancellationError {
            } catch {
                await MainActor.run { self?.onFailure?("Azure could not synthesize this selection. Check the endpoint, key, and voice.") }
            }
        }
    }

    func pause() { player?.pause() }
    func resume() { player?.play() }
    func setSpeed(_ multiplier: Float) {
        // Per-language speeds are baked into the synthesized audio; the global
        // setting then scales playback relative to that synthesis-time value.
        guard let player else { return }
        let ratio = Float(multiplier) / max(synthesisGlobalSpeed, 0.5)
        player.enableRate = true
        player.rate = min(max(ratio, 0.5), 2)
    }
    func stop() {
        synthesisTask?.cancel()
        synthesisTask = nil
        player?.stop()
        player = nil
    }

    private func play(_ data: Data) {
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            self.player = player
            guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
        } catch {
            onFailure?("Azure returned audio that Flow could not play.")
        }
    }

    private static func synthesize(plan: LanguageFlow.Plan, settings: FlowSettings, credentials: AzureSpeechCredentials) async throws -> Data {
        let body = try plan.sentences.map { sentence in
            let voiceName = sentence.route.azureVoiceName ?? settings.azureVoiceName
            let voice = voiceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !voice.isEmpty, voice.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                throw AzureConfigurationError.invalidVoice
            }
            // A Language check choice changes the route. Azure must receive
            // that chosen language rather than the detector's original guess.
            let languageTag = sentence.route.languageTag
            let escaped = sentence.text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            let rate = sentence.route.azureSpeechRate
            let speed = sentence.route.effectivePlaybackSpeed(default: settings.playbackSpeed)
            return "<voice name=\"\(voice)\"><lang xml:lang=\"\(languageTag)\"><prosody rate=\"\(azureRate(rate, speed: speed))%\">\(escaped)</prosody></lang></voice>"
        }.joined()
        let ssml = "<speak version=\"1.0\" xml:lang=\"\(settings.defaultLanguageTag)\">\(body)</speak>"
        var request = URLRequest(url: URL(string: credentials.endpoint + "/cognitiveservices/v1")!)
        request.httpMethod = "POST"
        request.setValue(credentials.subscriptionKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        request.setValue("audio-24khz-160kbitrate-mono-mp3", forHTTPHeaderField: "X-Microsoft-OutputFormat")
        request.setValue("Flow", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(ssml.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), !data.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func azureRate(_ rate: Float, speed: Float) -> Int {
        let minimum = AVSpeechUtteranceMinimumSpeechRate
        let maximum = AVSpeechUtteranceMaximumSpeechRate
        let position = min((rate - minimum) / (maximum - minimum) * speed, 1)
        return Int((position * 100 - 50).rounded())
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag { onFinished?() } else { onFailure?("Azure playback ended unexpectedly.") }
    }
}
