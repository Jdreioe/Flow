import AVFoundation

final class SystemSpeechEngine: NSObject, AVSpeechSynthesizerDelegate, FlowSpeechEngine {
    struct Voice: Identifiable, Hashable {
        let id: String
        let name: String
        let language: String
    }

    var onFinished: (() -> Void)?
    var onWordRange: ((Range<Int>?) -> Void)?
    var onPlaybackProgress: ((Double?) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var queuedUtterances = 0
    private var utteranceOffsets: [ObjectIdentifier: Int] = [:]
    private var highlightsWords = false
    private var totalCharacters = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    static var voices: [Voice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.identifier.contains(".siri.") }
            .map { voice in
                let localeName = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
                return Voice(id: voice.identifier, name: "\(voice.name) — \(localeName)", language: voice.language)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func defaultVoice(for languageTag: String) -> AVSpeechSynthesisVoice? {
        if let voice = AVSpeechSynthesisVoice(language: languageTag), !voice.identifier.contains(".siri.") {
            return voice
        }
        let base = languageTag.split(separator: "-").first?.lowercased()
        return AVSpeechSynthesisVoice.speechVoices().first {
            !$0.identifier.contains(".siri.") &&
                $0.language.split(separator: "-").first?.lowercased() == base
        }
    }

    func read(_ plan: LanguageFlow.Plan, settings: FlowSettings) {
        synthesizer.stopSpeaking(at: .immediate)
        queuedUtterances = plan.sentences.count
        utteranceOffsets = [:]
        highlightsWords = settings.wordHighlightingEnabled
        totalCharacters = plan.sentences.reduce(0) { $0 + $1.text.utf16.count + 1 }
        onPlaybackProgress?(totalCharacters > 0 ? 0 : nil)
        var offset = 0
        for sentence in plan.sentences {
            let utterance = AVSpeechUtterance(string: sentence.text)
            utterance.voice = sentence.route.systemVoiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
                ?? SystemSpeechEngine.defaultVoice(for: sentence.route.languageTag)
            utterance.rate = sentence.route.systemSpeechRate
            utteranceOffsets[ObjectIdentifier(utterance)] = offset
            offset += sentence.text.utf16.count + 1
            synthesizer.speak(utterance)
        }
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .immediate)
    }

    func resume() {
        synthesizer.continueSpeaking()
    }

    func stop() {
        queuedUtterances = 0
        utteranceOffsets = [:]
        totalCharacters = 0
        onWordRange?(nil)
        onPlaybackProgress?(nil)
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance,
    ) {
        guard let offset = utteranceOffsets[ObjectIdentifier(utterance)] else { return }
        if totalCharacters > 0 {
            let spoken = offset + characterRange.location
            onPlaybackProgress?(min(Double(spoken) / Double(totalCharacters), 1))
        }
        guard highlightsWords else { return }
        onWordRange?((offset + characterRange.location)..<(offset + characterRange.location + characterRange.length))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        utteranceOffsets.removeValue(forKey: ObjectIdentifier(utterance))
        queuedUtterances -= 1
        if queuedUtterances == 0 {
            onPlaybackProgress?(1)
            onFinished?()
        }
    }
}
