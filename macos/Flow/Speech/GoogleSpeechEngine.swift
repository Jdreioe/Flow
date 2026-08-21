import AVFoundation
import Foundation

enum GoogleCloudURLs {
    static let credentials = URL(string: "https://console.cloud.google.com/apis/credentials")!
    static let textToSpeechAPI = URL(string: "https://console.cloud.google.com/apis/library/texttospeech.googleapis.com")!
}

enum GoogleVoiceCatalog {
    struct Voice: Decodable, Identifiable, Hashable {
        let languageCodes: [String]
        let name: String
        let ssmlGender: String

        var id: String { name }

        var displayName: String {
            var parts = name.split(separator: "-")
            if let language = parts.first, (2...3).contains(language.count), language.allSatisfy(\.isLetter) {
                parts.removeFirst()
                if let region = parts.first, region.count == 2, region.allSatisfy(\.isUppercase) {
                    parts.removeFirst()
                }
            }
            return parts.joined(separator: "-")
        }

        func supports(languageTag: String) -> Bool {
            let base = languageTag.split(separator: "-").first?.lowercased()
            return languageCodes.contains {
                $0.split(separator: "-").first?.lowercased() == base
            }
        }
    }

    private struct Response: Decodable {
        let voices: [Voice]
    }

    static func list(apiKey: String) async throws -> [Voice] {
        var request = URLRequest(url: URL(string: "https://texttospeech.googleapis.com/v1/voices")!)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("Flow", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data).voices
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

final class GoogleSpeechEngine: NSObject, AVAudioPlayerDelegate, FlowSpeechEngine {
    private static let maximumInputBytes = 4_500

    var onFinished: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private var player: AVAudioPlayer?
    private var audioQueue: [Data] = []
    private var synthesisTask: Task<Void, Never>?

    func read(_ plan: LanguageFlow.Plan, settings: FlowSettings) {
        stop()
        guard let apiKey = GoogleCredentialsStore.load() else {
            onFailure?("Set up Google Cloud Text-to-Speech before choosing Google voice.")
            return
        }
        synthesisTask = Task { [weak self] in
            do {
                let audio = try await Self.synthesize(plan: plan, apiKey: apiKey)
                try Task.checkCancellation()
                await MainActor.run { self?.play(audio) }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    self?.onFailure?("Google Cloud could not synthesize this selection. Check the API key and voice.")
                }
            }
        }
    }

    func pause() { player?.pause() }
    func resume() { player?.play() }
    func stop() {
        synthesisTask?.cancel()
        synthesisTask = nil
        player?.stop()
        player = nil
        audioQueue = []
    }

    private func play(_ audio: [Data]) {
        audioQueue = audio
        playNextSegment()
    }

    private func playNextSegment() {
        guard !audioQueue.isEmpty else {
            player = nil
            onFinished?()
            return
        }
        do {
            let player = try AVAudioPlayer(data: audioQueue.removeFirst())
            player.delegate = self
            self.player = player
            guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
        } catch {
            audioQueue = []
            onFailure?("Google Cloud returned audio that Flow could not play.")
        }
    }

    private struct SynthesisRequest: Encodable {
        let input: Input
        let voice: Voice
        let audioConfig: AudioConfig

        struct Input: Encodable { let text: String }
        struct Voice: Encodable {
            let languageCode: String
            let name: String?
        }
        struct AudioConfig: Encodable {
            let audioEncoding = "MP3"
            let speakingRate: Float?
        }
    }

    private struct SynthesisResponse: Decodable {
        let audioContent: String
    }

    private static func synthesize(plan: LanguageFlow.Plan, apiKey: String) async throws -> [Data] {
        var audio: [Data] = []
        for sentence in plan.sentences {
            for chunk in textChunks(sentence.text) {
                try Task.checkCancellation()
                let requestBody = SynthesisRequest(
                    input: .init(text: chunk),
                    voice: .init(
                        languageCode: sentence.route.languageTag,
                        name: sentence.route.googleVoiceName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ),
                    audioConfig: .init(speakingRate: googleSpeakingRate(sentence.route.googleSpeechRate))
                )
                var request = URLRequest(url: URL(string: "https://texttospeech.googleapis.com/v1/text:synthesize")!)
                request.httpMethod = "POST"
                request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
                request.setValue("Flow", forHTTPHeaderField: "User-Agent")
                request.httpBody = try JSONEncoder().encode(requestBody)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                let encoded = try JSONDecoder().decode(SynthesisResponse.self, from: data).audioContent
                guard let segment = Data(base64Encoded: encoded), !segment.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                audio.append(segment)
            }
        }
        guard !audio.isEmpty else { throw URLError(.zeroByteResource) }
        return audio
    }

    private static func googleSpeakingRate(_ rate: Float) -> Float? {
        let minimum = AVSpeechUtteranceMinimumSpeechRate
        let maximum = AVSpeechUtteranceMaximumSpeechRate
        let position = (min(max(rate, minimum), maximum) - minimum) / (maximum - minimum)
        let speakingRate = 0.5 + position
        return abs(speakingRate - 1) > Float.ulpOfOne ? speakingRate : nil
    }

    private static func textChunks(_ text: String) -> [String] {
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var chunks: [String] = []
        while remaining.utf8.count > maximumInputBytes {
            var end = remaining.startIndex
            var byteCount = 0
            var lastWhitespace: String.Index?
            while end < remaining.endIndex {
                let next = remaining.index(after: end)
                let characterBytes = remaining[end..<next].utf8.count
                if byteCount + characterBytes > maximumInputBytes { break }
                if remaining[end].isWhitespace { lastWhitespace = end }
                byteCount += characterBytes
                end = next
            }
            let split = lastWhitespace ?? end
            chunks.append(String(remaining[..<split]).trimmingCharacters(in: .whitespacesAndNewlines))
            remaining = String(remaining[split...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !remaining.isEmpty { chunks.append(remaining) }
        return chunks
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag {
            playNextSegment()
        } else {
            audioQueue = []
            onFailure?("Google Cloud playback ended unexpectedly.")
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
