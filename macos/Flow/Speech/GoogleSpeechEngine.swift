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

        enum ModelFamily: CaseIterable, Hashable {
            case gemini
            case chirp3HD
            case studio
            case journey
            case polyglot
            case neural2
            case wavenet
            case news
            case standard
            case extended
            case chirpHD
            case other

            var title: String {
                switch self {
                case .gemini: "Gemini-TTS"
                case .chirp3HD: "Chirp 3 HD"
                case .studio: "Studio"
                case .journey: "Journey"
                case .polyglot: "Polyglot"
                case .neural2: "Neural2"
                case .wavenet: "WaveNet"
                case .news: "News"
                case .standard: "Standard"
                case .extended: "Extended"
                case .chirpHD: "Chirp HD"
                case .other: L10n.string("Other")
                }
            }
        }

        var modelFamily: ModelFamily {
            let variant = displayName.lowercased()
            if variant.hasPrefix("chirp3") { return .chirp3HD }
            switch variant.split(separator: "-").first {
            case "gemini": return .gemini
            case "studio": return .studio
            case "journey": return .journey
            case "polyglot": return .polyglot
            case "neural2": return .neural2
            case "wavenet": return .wavenet
            case "news": return .news
            case "standard": return .standard
            case "extended": return .extended
            case "chirp": return .chirpHD
            default: return .other
            }
        }

        func supports(languageTag: String) -> Bool {
            let base = languageTag.split(separator: "-").first?.lowercased()
            return languageCodes.contains {
                $0.split(separator: "-").first?.lowercased() == base
            }
        }
    }

    static func groupedByModelFamily(_ voices: [Voice]) -> [(family: Voice.ModelFamily, voices: [Voice])] {
        Voice.ModelFamily.allCases.compactMap { family in
            let members = voices.filter { $0.modelFamily == family }
            return members.isEmpty ? nil : (family, members)
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
    var onPlaybackStarted: (() -> Void)?
    var onWordRange: ((Range<Int>?) -> Void)?
    var onReadingOffset: ((Double?) -> Void)?
    private var player: AVAudioPlayer?
    private var segments: [PlaybackSegment] = []
    private var currentIndex = -1
    private var synthesisTask: Task<Void, Never>?
    private var playbackTimer: Timer?
    private var activeWordTimings: [WordTiming] = []
    private var activeWordIndex: Int?
    private var activeReadingOffset: Int?
    private var speedMultiplier: Float = 1
    private var activeSegmentSpeed: Float?

    func read(_ plan: LanguageFlow.Plan, settings: FlowSettings) {
        stop()
        speedMultiplier = min(max(settings.playbackSpeed, 0.5), 4)
        guard let apiKey = GoogleCredentialsStore.load() else {
            onFailure?(L10n.string("Set up Google Cloud Text-to-Speech before choosing Google voice."))
            return
        }
        synthesisTask = Task { [weak self] in
            do {
                let audio = try await Self.synthesize(plan: plan, apiKey: apiKey, includeWordTimings: settings.wordHighlightingEnabled)
                try Task.checkCancellation()
                await MainActor.run { self?.play(audio) }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    self?.onFailure?(L10n.string("Google Cloud could not synthesize this selection. Check the API key and voice."))
                }
            }
        }
    }

    func pause() { player?.pause() }
    func resume() { player?.play() }
    func setSpeed(_ multiplier: Float) {
        speedMultiplier = min(max(multiplier, 0.5), 4)
        // Languages with their own speed keep it; the rest follow the global.
        guard let player, activeSegmentSpeed == nil else { return }
        player.enableRate = true
        player.rate = speedMultiplier
    }
    func stop() {
        synthesisTask?.cancel()
        synthesisTask = nil
        player?.stop()
        player = nil
        segments = []
        currentIndex = -1
        playbackTimer?.invalidate()
        playbackTimer = nil
        activeWordTimings = []
        activeWordIndex = nil
        activeReadingOffset = nil
        activeSegmentSpeed = nil
        onWordRange?(nil)
        onReadingOffset?(nil)
    }

    private struct PlaybackSegment {
        let audio: AudioSegment
        let duration: TimeInterval
    }

    private func play(_ audio: [AudioSegment]) {
        var measured: [PlaybackSegment] = []
        for segment in audio {
            guard let probe = try? AVAudioPlayer(data: segment.data),
                  probe.duration.isFinite, probe.duration > 0 else {
                onFailure?(L10n.string("Google Cloud returned audio that Flow could not play."))
                return
            }
            measured.append(.init(audio: segment, duration: probe.duration))
        }
        segments = measured
        currentIndex = -1
        playSegment(at: 0)
    }

    private func playSegment(at index: Int, offset: TimeInterval = 0, autoplay: Bool = true) {
        guard index < segments.count else {
            player = nil
            onFinished?()
            return
        }
        do {
            let segment = segments[index]
            let player = try AVAudioPlayer(data: segment.audio.data)
            player.delegate = self
            player.currentTime = min(max(offset, 0), segment.duration)
            player.enableRate = true
            activeSegmentSpeed = segment.audio.speedOverride
            player.rate = segment.audio.speedOverride ?? speedMultiplier
            self.player = player
            currentIndex = index
            activeWordTimings = segment.audio.wordTimings
            activeWordIndex = nil
            activeReadingOffset = nil
            restartTimer()
            guard !autoplay || player.play() else { throw CocoaError(.fileReadCorruptFile) }
            if autoplay {
                onPlaybackStarted?()
            }
            updateWordHighlight()
        } catch {
            stop()
            onFailure?(L10n.string("Google Cloud returned audio that Flow could not play."))
        }
    }

    private func restartTimer() {
        playbackTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.updateWordHighlight()
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackTimer = timer
    }

    private struct SynthesisRequest: Encodable {
        let input: Input
        let voice: Voice
        let audioConfig: AudioConfig
        let enableTimePointing: [String]?

        struct Input: Encodable { let ssml: String }
        struct Voice: Encodable {
            let languageCode: String
            let name: String?
        }
        struct AudioConfig: Encodable {
            let audioEncoding: String
            let speakingRate: Float?
        }
    }

    private struct SynthesisResponse: Decodable {
        let audioContent: String
        let timepoints: [Timepoint]?

        struct Timepoint: Decodable {
            let markName: String
            let timeSeconds: Double
        }
    }

    struct WordTiming {
        let timeSeconds: Double
        let range: Range<Int>
    }

    struct AudioSegment {
        let data: Data
        let wordTimings: [WordTiming]
        let speedOverride: Float?
    }

    static func synthesize(plan: LanguageFlow.Plan, apiKey: String, includeWordTimings: Bool) async throws -> [AudioSegment] {
        var audio: [AudioSegment] = []
        var sentenceOffset = 0
        for sentence in plan.sentences {
            for chunk in textChunks(sentence.text) {
                try Task.checkCancellation()
                let marked = markedSSML(chunk.text)
                let requestBody = SynthesisRequest(
                    input: .init(ssml: marked.ssml),
                    voice: .init(
                        languageCode: sentence.route.languageTag,
                        name: sentence.route.googleVoiceName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ),
                    audioConfig: .init(
                        audioEncoding: "MP3",
                        speakingRate: googleSpeakingRate(sentence.route.googleSpeechRate)
                    ),
                    enableTimePointing: includeWordTimings ? ["SSML_MARK"] : nil
                )
                let apiVersion = includeWordTimings ? "v1beta1" : "v1"
                var request = URLRequest(url: URL(string: "https://texttospeech.googleapis.com/\(apiVersion)/text:synthesize")!)
                request.httpMethod = "POST"
                request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
                request.setValue("Flow", forHTTPHeaderField: "User-Agent")
                request.httpBody = try JSONEncoder().encode(requestBody)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                let responseBody = try JSONDecoder().decode(SynthesisResponse.self, from: data)
                let encoded = responseBody.audioContent
                guard let segment = Data(base64Encoded: encoded), !segment.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let timepoints = responseBody.timepoints ?? []
                let wordTimings = timepoints.compactMap { timepoint -> WordTiming? in
                    guard let index = Int(timepoint.markName.dropFirst(5)), marked.ranges.indices.contains(index) else { return nil }
                    let range = marked.ranges[index]
                    return WordTiming(
                        timeSeconds: timepoint.timeSeconds,
                        range: (sentenceOffset + chunk.offset + range.lowerBound)..<(sentenceOffset + chunk.offset + range.upperBound)
                    )
                }.sorted { $0.timeSeconds < $1.timeSeconds }
                audio.append(.init(
                    data: segment,
                    wordTimings: wordTimings,
                    speedOverride: sentence.route.playbackSpeed.map { min(max($0, 0.5), 4) },
                ))
            }
            sentenceOffset += sentence.text.utf16.count + 1
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

    private static func textChunks(_ text: String) -> [(text: String, offset: Int)] {
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var chunks: [(text: String, offset: Int)] = []
        var offset = text.utf16.count - remaining.utf16.count
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
            let chunk = String(remaining[..<split]).trimmingCharacters(in: .whitespacesAndNewlines)
            chunks.append((chunk, offset))
            let consumed = String(remaining[..<split])
            remaining = String(remaining[split...])
            offset += consumed.utf16.count
            let trimmed = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
            offset += remaining.utf16.count - trimmed.utf16.count
            remaining = trimmed
        }
        if !remaining.isEmpty { chunks.append((remaining, offset)) }
        return chunks
    }

    private static func markedSSML(_ text: String) -> (ssml: String, ranges: [Range<Int>]) {
        var ssml = "<speak>"
        var ranges: [Range<Int>] = []
        var wordStart: Int?
        var utf16Offset = 0
        for character in text {
            if character.isWhitespace {
                if let start = wordStart {
                    ranges.append(start..<utf16Offset)
                    wordStart = nil
                }
            } else if wordStart == nil {
                wordStart = utf16Offset
                ssml += "<mark name=\"word_\(ranges.count)\"/>"
            }
            switch character {
            case "&": ssml += "&amp;"
            case "<": ssml += "&lt;"
            case ">": ssml += "&gt;"
            default: ssml.append(character)
            }
            utf16Offset += String(character).utf16.count
        }
        if let start = wordStart { ranges.append(start..<utf16Offset) }
        return (ssml + "</speak>", ranges)
    }

    private func updateWordHighlight() {
        guard let player else { return }
        let index = activeWordTimings.lastIndex { $0.timeSeconds <= player.currentTime }
        if index != activeWordIndex {
            activeWordIndex = index
            onWordRange?(index.map { activeWordTimings[$0].range })
        }
        guard let index else {
            if activeReadingOffset != nil {
                activeReadingOffset = nil
                onReadingOffset?(nil)
            }
            return
        }
        let current = activeWordTimings[index]
        guard activeWordTimings.indices.contains(index + 1) else {
            reportReadingOffset(current.range.lowerBound)
            return
        }
        let next = activeWordTimings[index + 1]
        let interval = next.timeSeconds - current.timeSeconds
        let progress = interval > 0 ? (player.currentTime - current.timeSeconds) / interval : 0
        let offset = Double(current.range.lowerBound)
            + Double(next.range.lowerBound - current.range.lowerBound) * min(max(progress, 0), 1)
        reportReadingOffset(Int(offset.rounded(.down)))
    }

    private func reportReadingOffset(_ offset: Int) {
        guard offset != activeReadingOffset else { return }
        activeReadingOffset = offset
        onReadingOffset?(Double(offset))
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag {
            playbackTimer?.invalidate()
            playbackTimer = nil
            // Keep the last position visible while the next sentence's audio
            // player is prepared. Clearing it briefly makes the popup fall
            // back to the start of the full text between sentences.
            playSegment(at: currentIndex + 1)
        } else {
            stop()
            onFailure?(L10n.string("Google Cloud playback ended unexpectedly."))
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
