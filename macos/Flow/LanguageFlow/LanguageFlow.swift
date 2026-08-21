import Foundation
import NaturalLanguage

enum LanguageFlow {
    static let uncertainConfidence = 0.75
    static let uncertainLead = 0.15

    struct Sentence: Identifiable {
        let id = UUID()
        let text: String
        let detectedLanguageTag: String?
        var route: FlowSettings.LanguageRoute
        var needsReview: Bool
        let detectedButUnconfigured: Bool
    }

    struct Plan {
        var sentences: [Sentence]
        var needsLanguageCheck: Bool { sentences.contains(where: \.needsReview) }
    }

    static func singleSentence(_ text: String, settings: FlowSettings) -> Plan {
        Plan(sentences: [Sentence(
            text: text,
            detectedLanguageTag: settings.defaultLanguageTag,
            route: settings.defaultLanguageRoute,
            needsReview: false,
            detectedButUnconfigured: false,
        )])
    }

    // Rejoins the hard line wraps that PDFs and some editors insert mid-sentence
    // so text-to-speech does not pause at every visual line break. Blank lines
    // and list items keep their breaks because those pauses are intentional.
    static func reflow(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var paragraphs: [String] = []
        var fragments: [String] = []

        func flush() {
            guard !fragments.isEmpty else { return }
            paragraphs.append(fragments.joined(separator: " "))
            fragments.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                continue
            }
            if startsNewBlock(trimmed) {
                flush()
                // Open a new fragment instead of closing the paragraph so the
                // wrapped lines after a bullet or number keep flowing into it.
                fragments.append(trimmed)
                continue
            }
            if let previous = fragments.last {
                fragments[fragments.count - 1] = join(previous, nextLine: trimmed)
            } else {
                fragments.append(trimmed)
            }
        }
        flush()
        return paragraphs.joined(separator: "\n\n")
    }

    private static func startsNewBlock(_ line: String) -> Bool {
        let characters = Array(line)
        guard let first = characters.first else { return false }
        if ["•", "·", "‣", "⁃", "▪", "◦"].contains(where: line.hasPrefix) {
            return true
        }
        if "-–—*".contains(first), characters.count > 1, characters[1].isWhitespace {
            return true
        }
        guard first.isNumber else { return false }
        guard let index = characters.firstIndex(where: { !$0.isNumber }) else { return false }
        return ".)".contains(characters[index]) || characters[index].isWhitespace
    }

    private static func join(_ previous: String, nextLine: String) -> String {
        let previousCharacters = Array(previous)
        guard let last = previousCharacters.last else { return previous + " " + nextLine }
        let nextStartsLowercase = nextLine.first?.isLowercase == true || nextLine.first?.isNumber == true
        if last == "-", nextStartsLowercase {
            // Keep the hyphen only when it is part of a longer compound such as
            // "system-of-interest"; drop it when it was inserted by line wrapping.
            let continuationWord = nextLine.prefix(while: { !$0.isWhitespace })
            if continuationWord.contains("-") {
                return previous + nextLine
            }
            return String(previous.dropLast()) + nextLine
        }
        // A sentence end mid-paragraph keeps a break; NLTokenizer still merges
        // reading into natural sentences without wrap-induced pauses elsewhere.
        let previousEndsSentence = ".!?…".contains(last)
        let previousEndsWithClosingQuote = "\"'”’)]»".contains(last)
            && previous.dropLast().last.map { ".!?…".contains($0) } == true
        let joinsNaturally = nextStartsLowercase || nextLine.hasPrefix("(")
        if (previousEndsSentence && !previousEndsWithClosingQuote) || !joinsNaturally {
            return previous + "\n" + nextLine
        }
        return previous + " " + nextLine
    }

    static func plan(text: String, settings: FlowSettings) -> Plan {
        plan(text: text, settings: settings, overrideTag: nil)
    }

    // Plans a selection with sentence detection suspended: every sentence is
    // read with the override language's route (falling back to the default
    // route when that language is not configured) and never needs review.
    static func plan(text: String, settings: FlowSettings, overrideTag: String?) -> Plan {
        guard let tag = overrideTag else {
            return detectedPlan(text: text, settings: settings)
        }
        let preparedText = reflow(text)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = preparedText
        var sentences: [Sentence] = []
        tokenizer.enumerateTokens(in: preparedText.startIndex..<preparedText.endIndex) { range, _ in
            let sentence = String(preparedText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return true }
            sentences.append(Sentence(
                text: sentence,
                detectedLanguageTag: tag,
                route: settings.languageRoute(for: tag) ?? settings.defaultLanguageRoute,
                needsReview: false,
                detectedButUnconfigured: false,
            ))
            return true
        }
        if sentences.isEmpty {
            let fallback = singleSentence(text, settings: settings).sentences[0]
            return Plan(sentences: [Sentence(
                text: fallback.text,
                detectedLanguageTag: tag,
                route: fallback.route,
                needsReview: false,
                detectedButUnconfigured: false,
            )])
        }
        return Plan(sentences: sentences)
    }

    private static func detectedPlan(text: String, settings: FlowSettings) -> Plan {
        let preparedText = reflow(text)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = preparedText
        var sentences: [Sentence] = []
        tokenizer.enumerateTokens(in: preparedText.startIndex..<preparedText.endIndex) { range, _ in
            let sentence = String(preparedText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return true }
            let detection = detect(sentence)
            // Detect from the first reading. A detected, unconfigured language must
            // open Language check so the person can enable it; otherwise the first
            // added route can never be discovered.
            let switchingIsActive = settings.languageSwitchingEnabled
            let route = switchingIsActive
                ? detection.tag.flatMap { settings.languageRoute(for: $0) }
                : nil
            let configured = route != nil
            let uncertain = detection.confidence < uncertainConfidence || detection.lead < uncertainLead
            let shouldCheck = switchingIsActive && (uncertain || !configured)
            sentences.append(Sentence(
                text: sentence,
                detectedLanguageTag: detection.tag,
                route: route ?? settings.defaultLanguageRoute,
                needsReview: shouldCheck,
                detectedButUnconfigured: detection.tag != nil && !configured,
            ))
            return true
        }
        return Plan(sentences: sentences.isEmpty ? singleSentence(text, settings: settings).sentences : sentences)
    }

    private static func detect(_ text: String) -> (tag: String?, confidence: Double, lead: Double) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
            .sorted { $0.value > $1.value }
        guard let first = hypotheses.first else { return (nil, 0, 0) }
        let second = hypotheses.dropFirst().first?.value ?? 0
        return (FlowLanguageOption.defaultTag(for: first.key.rawValue), first.value, first.value - second)
    }
}

enum FlowLanguageOption: String, CaseIterable, Identifiable {
    case english = "en-US"
    case danish = "da-DK"
    case swedish = "sv-SE"
    case norwegian = "nb-NO"
    case german = "de-DE"
    case french = "fr-FR"
    case spanish = "es-ES"
    case italian = "it-IT"
    case dutch = "nl-NL"
    case portuguese = "pt-PT"

    var id: String { rawValue }
    var tag: String { rawValue }
    var title: String { Locale.current.localizedString(forIdentifier: rawValue) ?? rawValue }

    static func defaultTag(for detectedTag: String) -> String {
        let base = detectedTag.split(separator: "-").first?.lowercased()
        return allCases.first { $0.tag.split(separator: "-").first?.lowercased() == base }?.tag ?? detectedTag
    }
}
