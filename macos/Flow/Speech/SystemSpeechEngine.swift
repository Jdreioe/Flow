import AVFoundation

final class SystemSpeechEngine: NSObject, AVSpeechSynthesizerDelegate, FlowSpeechEngine {
    struct Voice: Identifiable, Hashable {
        let id: String
        let name: String
        let language: String
    }

    var onFinished: (() -> Void)?
    var onWordRange: ((Range<Int>?) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var queuedUtterances = 0
    private var utteranceOffsets: [ObjectIdentifier: Int] = [:]
    private var utteranceRates: [ObjectIdentifier: Float] = [:]
    private var speedOverrides: [ObjectIdentifier: Float] = [:]
    private var spokenQueue: [AVSpeechUtterance] = []
    private var currentIndex = 0
    private var speedMultiplier: Float = 1
    private var highlightsWords = false
    private var isPaused = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    static var voices: [Voice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter(isListable)
            .map { voice in
                let localeName = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
                return Voice(id: voice.identifier, name: "\(voice.name) — \(localeName)", language: voice.language)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func isListable(_ voice: AVSpeechSynthesisVoice) -> Bool {
        !voice.identifier.contains(".siri.")
            && !voice.identifier.contains("<+>")
    }

    static func defaultVoice(for languageTag: String) -> AVSpeechSynthesisVoice? {
        if let voice = AVSpeechSynthesisVoice(language: languageTag), isListable(voice) {
            return voice
        }
        let base = languageTag.split(separator: "-").first?.lowercased()
        return AVSpeechSynthesisVoice.speechVoices().first {
            isListable($0) &&
                $0.language.split(separator: "-").first?.lowercased() == base
        }
    }

    func read(_ plan: LanguageFlow.Plan, settings: FlowSettings) {
        synthesizer.stopSpeaking(at: .immediate)
        queuedUtterances = plan.sentences.count
        utteranceOffsets = [:]
        utteranceRates = [:]
        speedOverrides = [:]
        spokenQueue = []
        currentIndex = 0
        speedMultiplier = min(max(settings.playbackSpeed, 0.5), 4)
        highlightsWords = settings.wordHighlightingEnabled
        var offset = 0
        for sentence in plan.sentences {
            let utterance = AVSpeechUtterance(string: sentence.text)
            utterance.voice = sentence.route.systemVoiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
                ?? SystemSpeechEngine.defaultVoice(for: sentence.route.languageTag)
            let identifier = ObjectIdentifier(utterance)
            if let overrideSpeed = sentence.route.playbackSpeed {
                speedOverrides[identifier] = min(max(overrideSpeed, 0.5), 4)
            }
            utterance.rate = rate(for: identifier, baseRate: sentence.route.systemSpeechRate)
            utteranceOffsets[identifier] = offset
            utteranceRates[identifier] = sentence.route.systemSpeechRate
            spokenQueue.append(utterance)
            offset += sentence.text.utf16.count + 1
            synthesizer.speak(utterance)
        }
    }

    private func rate(for identifier: ObjectIdentifier, baseRate: Float) -> Float {
        let effective = speedOverrides[identifier] ?? speedMultiplier
        return min(baseRate * effective, AVSpeechUtteranceMaximumSpeechRate)
    }

    func setSpeed(_ multiplier: Float) {
        speedMultiplier = min(max(multiplier, 0.5), 4)
        for utterance in spokenQueue {
            let identifier = ObjectIdentifier(utterance)
            guard let baseRate = utteranceRates[identifier] else { continue }
            utterance.rate = rate(for: identifier, baseRate: baseRate)
        }
        // AVSpeechSynthesizer cannot change the rate of the active utterance,
        // so the current sentence restarts with the new rate; later sentences
        // simply speak with it. While paused only the rates are updated.
        guard !isPaused, queuedUtterances > 0, currentIndex < spokenQueue.count else { return }
        synthesizer.stopSpeaking(at: .immediate)
        queuedUtterances = spokenQueue.count - currentIndex
        for utterance in spokenQueue[currentIndex...] {
            synthesizer.speak(utterance)
        }
    }

    func pause() {
        isPaused = true
        synthesizer.pauseSpeaking(at: .immediate)
    }

    func resume() {
        isPaused = false
        synthesizer.continueSpeaking()
    }

    func stop() {
        queuedUtterances = 0
        utteranceOffsets = [:]
        utteranceRates = [:]
        speedOverrides = [:]
        spokenQueue = []
        currentIndex = 0
        speedMultiplier = 1
        isPaused = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance,
    ) {
        guard let offset = utteranceOffsets[ObjectIdentifier(utterance)] else { return }
        if let index = spokenQueue.firstIndex(where: { ObjectIdentifier($0) == ObjectIdentifier(utterance) }) {
            currentIndex = index
        }
        guard highlightsWords else { return }
        onWordRange?((offset + characterRange.location)..<(offset + characterRange.location + characterRange.length))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        utteranceOffsets.removeValue(forKey: ObjectIdentifier(utterance))
        queuedUtterances -= 1
        if queuedUtterances == 0 { onFinished?() }
    }
}
