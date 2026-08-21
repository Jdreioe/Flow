import AVFoundation

final class SystemSpeechEngine: NSObject, AVSpeechSynthesizerDelegate, FlowSpeechEngine {
    struct Voice: Identifiable, Hashable {
        let id: String
        let name: String
        let language: String
    }

    var onFinished: (() -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var queuedUtterances = 0

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
        for sentence in plan.sentences {
            let utterance = AVSpeechUtterance(string: sentence.text)
            utterance.voice = sentence.route.systemVoiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
                ?? SystemSpeechEngine.defaultVoice(for: sentence.route.languageTag)
            utterance.rate = sentence.route.systemSpeechRate
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
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        queuedUtterances -= 1
        if queuedUtterances == 0 { onFinished?() }
    }
}
