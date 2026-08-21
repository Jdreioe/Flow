import Foundation
import NaturalLanguage

enum LanguageFlow {
    struct Sentence: Identifiable {
        let id = UUID()
        let text: String
        let detectedLanguageTag: String?
        var route: FlowSettings.LanguageRoute
        var needsReview: Bool
        var detectedButUnconfigured: Bool
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

    // The speech engines use one UTF-16 code unit between sentence offsets.
    // A newline is also one code unit, so it can preserve paragraph structure
    // in the popup without shifting the word-boundary ranges.
    static func playbackText(for plan: Plan, sourceText: String) -> String {
        guard plan.sentences.count > 1 else { return plan.sentences.first?.text ?? sourceText }
        let reflowed = reflow(sourceText)
        var ranges: [Range<String.Index>] = []
        var searchStart = reflowed.startIndex
        for sentence in plan.sentences {
            guard let range = reflowed.range(of: sentence.text, range: searchStart..<reflowed.endIndex) else {
                return plan.sentences.map(\.text).joined(separator: " ")
            }
            ranges.append(range)
            searchStart = range.upperBound
        }
        return plan.sentences.indices.map { index in
            let sentence = plan.sentences[index].text
            guard index < plan.sentences.index(before: plan.sentences.endIndex) else { return sentence }
            let whitespace = reflowed[ranges[index].upperBound..<ranges[index + 1].lowerBound]
            return sentence + (whitespace.contains("\n\n") ? "\n" : " ")
        }.joined()
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
            let detection = detect(sentence, settings: settings)
            let route = detection.route
            let configured = route != nil
            let shouldCheck = !configured
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

    // Copy of the plan with every review flag cleared, for paths that must
    // never block playback (see ADR 0003).
    static func withoutReview(_ plan: Plan) -> Plan {
        var plan = plan
        for index in plan.sentences.indices {
            plan.sentences[index].needsReview = false
            plan.sentences[index].detectedButUnconfigured = false
        }
        return plan
    }

    private static func detect(
        _ text: String,
        settings: FlowSettings,
    ) -> (tag: String?, confidence: Double, lead: Double, route: FlowSettings.LanguageRoute?) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: SupportedLanguage.all.count)
            .sorted { $0.value > $1.value }
        guard let first = hypotheses.first else { return (nil, 0, 0, nil) }
        let detectedTag = SupportedLanguage.canonicalTag(for: first.key.rawValue)
        let second = hypotheses.dropFirst().first?.value ?? 0
        var configured: (String, FlowSettings.LanguageRoute)?
        for hypothesis in hypotheses {
            let tag = SupportedLanguage.canonicalTag(for: hypothesis.key.rawValue)
            guard SupportedLanguage.sharesAutomaticLanguageGroup(detectedTag, tag) else { continue }
            if let route = settings.languageRoute(for: tag) {
                configured = (tag, route)
                break
            }
        }
        let tag = configured?.0 ?? detectedTag
        return (tag, first.value, first.value - second, configured?.1)
    }
}

struct SupportedLanguage: Identifiable, Hashable {
    let tag: String
    let name: String

    var id: String { tag }
    var title: String { Locale.current.localizedString(forIdentifier: tag) ?? name }

    // Mirrors the shared core's supported language list
    // (core/src/language.rs). The Swift/Rust bridge that would drive this
    // from the core directly is deferred (ADR 0001); keep both lists in
    // sync until it lands.
    static let all: [SupportedLanguage] = [
        .init(tag: "en-US", name: "English"),
        .init(tag: "da-DK", name: "Danish"),
        .init(tag: "sv-SE", name: "Swedish"),
        .init(tag: "nb-NO", name: "Norwegian Bokmål"),
        .init(tag: "de-DE", name: "German"),
        .init(tag: "fr-FR", name: "French"),
        .init(tag: "es-ES", name: "Spanish"),
        .init(tag: "it-IT", name: "Italian"),
        .init(tag: "nl-NL", name: "Dutch"),
        .init(tag: "pt-PT", name: "Portuguese"),
    ]

    static func canonicalTag(for detectedTag: String) -> String {
        let base = detectedTag.split(separator: "-").first?.lowercased()
        return all.first { $0.tag.split(separator: "-").first?.lowercased() == base }?.tag ?? detectedTag
    }

    static func sharesAutomaticLanguageGroup(_ detectedTag: String, _ candidateTag: String) -> Bool {
        if detectedTag.caseInsensitiveCompare(candidateTag) == .orderedSame {
            return true
        }

        let scandinavian = ["da-DK", "sv-SE", "nb-NO"]
        return scandinavian.contains(detectedTag) && scandinavian.contains(candidateTag)
    }
}
