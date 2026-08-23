import Foundation
import NaturalLanguage

/// A detection layer. One per strategy so each is testable in isolation and the
/// engine can run/omit layers independently (cheapest-first, LLM never required).
public protocol EntityDetector: Sendable {
    var source: DetectionSource { get }
    func detect(in input: DetectionInput) async throws -> [DetectedEntity]
}

// MARK: - Layer 2a: Apple's built-in data detectors

/// `NSDataDetector` for emails, phone numbers, URLs, dates, and postal addresses.
public struct DataDetectorDetector: EntityDetector {
    public let source: DetectionSource = .dataDetector
    private let checkingTypes: NSTextCheckingResult.CheckingType = [.link, .phoneNumber, .date, .address]

    public init() {}

    public func detect(in input: DetectionInput) async throws -> [DetectedEntity] {
        guard case let .text(text) = input, !text.isEmpty else { return [] }
        let detector = try NSDataDetector(types: checkingTypes.rawValue)
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var results: [DetectedEntity] = []
        detector.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match, let range = Range(match.range, in: text) else { return }
            results.append(
                DetectedEntity(
                    type: Self.category(for: match),
                    value: String(text[range]),
                    confidence: 0.85,
                    source: .dataDetector,
                    locus: .text(range)
                )
            )
        }
        return results
    }

    private static func category(for match: NSTextCheckingResult) -> EntityType {
        switch match.resultType {
        case .phoneNumber: return .phone
        case .date: return .date
        case .address: return .address
        case .link:
            // NSDataDetector surfaces bare emails as `mailto:` links.
            if match.url?.scheme?.lowercased() == "mailto" { return .email }
            return .url
        default: return .other("dataDetector")
        }
    }
}

// MARK: - Layer 2b: data-driven regex ruleset

/// Structured identifiers (SSN, MRN, account, IP, JWT, …) from the editable ruleset.
public struct RegexRulesetDetector: EntityDetector {
    public let source: DetectionSource = .regex

    private struct Compiled {
        let type: EntityType
        let confidence: Double
        let disposition: Disposition
        let regex: NSRegularExpression
    }
    private let compiled: [Compiled]

    public init(ruleset: Ruleset) throws {
        self.compiled = try ruleset.rules.map { rule in
            do {
                let options: NSRegularExpression.Options = rule.caseInsensitive == true ? [.caseInsensitive] : []
                return Compiled(
                    type: EntityType(identifier: rule.type),
                    confidence: rule.confidence,
                    disposition: rule.disposition ?? .redact,
                    regex: try NSRegularExpression(pattern: rule.pattern, options: options)
                )
            } catch {
                throw ClipscrubError.invalidPattern(rule: rule.name, underlying: "\(error)")
            }
        }
    }

    public func detect(in input: DetectionInput) async throws -> [DetectedEntity] {
        guard case let .text(text) = input, !text.isEmpty else { return [] }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var results: [DetectedEntity] = []
        for rule in compiled {
            rule.regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                guard let match, let range = Range(match.range, in: text) else { return }
                results.append(
                    DetectedEntity(
                        type: rule.type,
                        value: String(text[range]),
                        confidence: rule.confidence,
                        source: .regex,
                        locus: .text(range),
                        disposition: rule.disposition
                    )
                )
            }
        }
        return results
    }
}

// MARK: - Layer 3: on-device NER

/// `NLTagger` `.nameType` for person / place / organisation names.
public struct NameEntityDetector: EntityDetector {
    public let source: DetectionSource = .nlTagger

    public init() {}

    public func detect(in input: DetectionInput) async throws -> [DetectedEntity] {
        guard case let .text(text) = input, !text.isEmpty else { return [] }
        // One tagger for every pass below, instead of one per pass and one per line. Building an
        // `NLTagger` loads the name model; re-assigning `.string` does not. On a 200-line page that
        // was 202 constructions, and this detector is where the text stage spends most of its time.
        // Safe because the passes run in order on one input: nothing here is concurrent, and the
        // tagger holds no state across a `.string` assignment.
        let tagger = NLTagger(tagSchemes: [.nameType])
        var results = tagNames(tagString: text, sourceString: text, using: tagger)

        // NLTagger's name model leans on capitalization, so ALL-CAPS ("JANICE") and lowercase names
        // are missed. Re-run on a length-preserving Title-Cased copy and map the spans back.
        // This over-flags some prose ("fox trot dippy dappy" reads as a name), but that is the SAFE
        // direction for a redactor: an over-redacted word is recoverable, a leaked name is not. The
        // name-instability the user hit lived in the LLM tier, which the DetectionEngine gate trims.
        let normalized = Self.titleCased(text)
        if normalized != text {
            Self.merge(tagNames(tagString: normalized, sourceString: text, using: tagger), into: &results)
        }

        Self.merge(carriedLineNames(in: text, using: tagger), into: &results)
        return Self.dropNamesThatAreNotNames(results, in: text)
    }

    /// Clinical writing is full of proper nouns that name a thing rather than a person. `Parkinson's
    /// disease` tags as an organisation and `Beck Depression Inventory-II` tags as a name plus a
    /// place, so a note came back as `Patient has [ORG_1]'s disease.` — the reader loses the reason
    /// the note was being shared, which is the same harm as blacking out a diagnosis code.
    ///
    /// This removes ONLY spans this detector produced, so nothing another layer found can be lost to
    /// it. `CommonNameDetector` runs alongside and independently re-finds anything dropped here that
    /// is one of the given names on its list — which is a real backstop for `Sarah` and no help at
    /// all for a surname, since that list holds given names only. The guards below are what protects
    /// a surname, and they are the whole safety argument.
    ///
    /// Three guards, each of which is a real name the frames would otherwise take:
    ///
    ///     Alice Parkinson's disease is stable.    more than one word → kept
    ///     Mx. Renner's disease has progressed.    a title before it  → kept
    ///     Alice's disease is stable.              a name in frame    → kept
    static func dropNamesThatAreNotNames(_ results: [DetectedEntity], in text: String) -> [DetectedEntity] {
        let frames = nonPersonFrames(in: text)
        guard !frames.isEmpty else { return results }
        return results.filter { entity in
            guard case let .text(span) = entity.locus else { return true }
            // Every frame the span sits inside, not the first one found. Two frames can overlap on
            // one span, and a narrower one with no name in it would otherwise decide alone.
            let enclosing = frames.filter { $0.lowerBound <= span.lowerBound && span.upperBound <= $0.upperBound }
            guard !enclosing.isEmpty else { return true }
            // More than one word is a person far more often than it is part of a phrase, and there is
            // no way to tell the two apart from the text: `Renner Voss Questionnaire` and
            // `Hamilton Anxiety Questionnaire` are the same three words in the same order. So a
            // multi-word span is always kept, and an instrument whose whole name tags as one span
            // goes on being over-redacted. That is the safe direction — a covered word can be read
            // back off the original, a leaked surname cannot. A hyphen joins words the same way a
            // space does, or `Lloyd-Jones Battery` reads as one word and loses the surname.
            if text[span].contains(where: { $0.isWhitespace || $0 == "-" }) { return true }
            if isPrecededByTitle(span, in: text) { return true }
            if enclosing.contains(where: { frameContainsAKnownName(text[$0]) }) { return true }
            return false
        }
    }

    /// True when any word in the frame is a known given name. The apostrophe has to be a separator:
    /// keeping it inside the word makes `Alice's disease` split to `alice's`, which no gazetteer
    /// entry can ever match, so the guard is silently dead on the commonest spelling of an eponym.
    private static func frameContainsAKnownName(_ frame: Substring) -> Bool {
        frame.split { !$0.isLetter }.map { $0.lowercased() }.contains { CommonNameDetector.names.contains($0) }
    }

    /// Stretches of text that name a condition or an instrument rather than a person.
    ///
    /// The head nouns are deliberately short lists of the words that make a phrase one of these, not
    /// lists of conditions or instruments — there is no end to those. Words that also follow a real
    /// name in ordinary writing are left out even where they are genuinely eponym words: `sign`,
    /// `law`, `area` and `node` cost `Nwosu's law firm called.` and `Okonkwo's area of residence`,
    /// `Schedule` costs `Ferguson Discharge Schedule`, and `test`, `scale` and `index` cost
    /// `Ms. Beck's test` and `Maria Gonzalez Test`.
    ///
    /// A frame never crosses a line. OCR wraps a line wherever the page did, so a frame that spans
    /// the break joins two sentences that were never next to each other.
    private static func nonPersonFrames(in text: String) -> [Range<String.Index>] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return [eponymPattern, instrumentPattern].compactMap { $0 }.flatMap { pattern in
            pattern.matches(in: text, options: [], range: range).compactMap { Range($0.range, in: text) }
        }
    }

    /// `Parkinson's disease`, `Babinski's reflex`. A person's name written possessively in front of
    /// one of these is naming the condition, not the patient.
    static let eponymPattern = try? NSRegularExpression(
        pattern: "\\b[A-Z][A-Za-z'\u{2019}-]*['\u{2019}]s[ \t](?:disease|syndrome|reflex|phenomenon|triad|manoeuvre|maneuver|gland)\\b"
    )

    /// `Beck Depression Inventory-II`, `Hamilton Anxiety Questionnaire`. The optional tail is the
    /// edition, which tags as a place on its own and has to fall inside the frame to be dropped.
    ///
    /// At least two words have to come before the head noun. One is how a person is written —
    /// `Wilson Battery ordered for follow-up.` is a surname and a piece of hardware, and framing it
    /// dropped the surname. An instrument named after one person carries what it measures too.
    static let instrumentPattern = try? NSRegularExpression(
        pattern: "\\b[A-Z][A-Za-z]*(?:[ -][A-Z][A-Za-z]*){1,3}[ ](?:Inventory|Questionnaire|Battery|Subscale)(?:-(?:[IVXL]+|[0-9]+))?\\b"
    )

    /// True when a title sits immediately before the span. `Mx. Renner's disease has progressed.` is
    /// about a person whatever follows, and the title is the only thing in the sentence that says so.
    ///
    /// A line break counts as a space rather than ending the search. OCR wraps a line wherever the
    /// page did, so `Dr.` and the surname after it land on separate lines often — and treating the
    /// break as the end of the search turns the guard off for exactly those names.
    ///
    /// Eight characters back covers the longest title here plus its stop and a space (`Prof. ` is
    /// six). Reading further would start finding titles that belong to someone else in the sentence.
    private static func isPrecededByTitle(_ span: Range<String.Index>, in text: String) -> Bool {
        let window = text.index(span.lowerBound, offsetBy: -8, limitedBy: text.startIndex) ?? text.startIndex
        let before = String(text[window..<span.lowerBound].map { $0.isNewline ? " " : $0 })
        return titlePattern?.firstMatch(in: before, options: [],
                                        range: NSRange(before.startIndex..<before.endIndex, in: before)) != nil
    }

    /// The full stop is enough on its own, because `Mr.Renner` with no space is how a tight layout
    /// or an OCR read of one comes out. No input demonstrates this widening: `NLTagger` does not tag
    /// a name written that way at all, so the span never reaches this guard. It is here because the
    /// shape is real, not because it fixed something measured.
    static let titlePattern = try? NSRegularExpression(
        pattern: "(?:^|\\s)(?:Mr|Mrs|Ms|Miss|Mx|Dr|Prof|Sr|Sra|Rev)(?:\\.\\s*|\\s+)$"
    )

    /// Keep only the hits that cover new ground. A second pass re-finds most of what the first one
    /// did, and the engine resolves overlaps across detectors, not within one.
    ///
    /// A candidate that swallows what it overlaps replaces it, because the narrower span is the one
    /// that leaks: an earlier pass reads "K. Nwosu (intake)" as just "Nwosu", and keeping that
    /// covers the surname while leaving the initial in the clear.
    private static func merge(_ candidates: [DetectedEntity], into results: inout [DetectedEntity]) {
        for entity in candidates {
            guard case let .text(newRange) = entity.locus else { continue }
            let overlapping = results.indices.filter {
                if case let .text(existing) = results[$0].locus { return existing.overlaps(newRange) }
                return false
            }
            let swallowsAll = overlapping.allSatisfy {
                guard case let .text(existing) = results[$0].locus else { return false }
                return existing.lowerBound >= newRange.lowerBound && existing.upperBound <= newRange.upperBound
            }
            guard swallowsAll else { continue }
            for index in overlapping.reversed() { results.remove(at: index) }
            results.append(entity)
        }
    }

    /// The name model reads sentence context, so a bare column of names — a calendar, a roster, a
    /// spreadsheet column — tags as nothing at all: "Dee Okonkwo" alone is missed where the same
    /// name in a sentence is found. Each line is re-tagged inside a carrier sentence and the hits
    /// are mapped back. Any sentence does the job, so the wording is not tuned to what is scanned.
    private func carriedLineNames(in text: String, using tagger: NLTagger) -> [DetectedEntity] {
        var results: [DetectedEntity] = []
        var lineStart = text.startIndex
        while true {
            // Any newline ends a line, not just "\n". Swift reads CRLF as ONE character, so looking
            // for "\n" finds nothing in a Windows document and the whole file arrives here as a
            // single line — which is every document this pass exists to help, wrapped in one
            // useless sentence.
            let lineEnd = text[lineStart...].firstIndex(where: \.isNewline) ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            // The guard below keeps only a span of two or more words, and a line of one word cannot
            // produce one. Tagging it anyway is the commonest wasted pass on a table or a form,
            // where most cells hold a single token.
            if !line.isEmpty, Self.hasTwoWords(line) {
                let carried = Self.carrierPrefix + line + Self.carrierSuffix
                let lineLower = carried.index(carried.startIndex, offsetBy: Self.carrierPrefix.count)
                let lineUpper = carried.index(lineLower, offsetBy: line.count)
                for (type, range) in Self.taggedRanges(in: carried, using: tagger)
                where type == .name && range.lowerBound >= lineLower && range.upperBound <= lineUpper {
                    // One token inside a sentence we invented is the weakest evidence there is — a
                    // day label reads as a name that way — and a standalone given name is already
                    // the bundled-list layer's job.
                    guard carried[range].split(separator: " ").count > 1 else { continue }
                    let offset = carried.distance(from: lineLower, to: range.lowerBound)
                    let length = carried.distance(from: range.lowerBound, to: range.upperBound)
                    let start = text.index(lineStart, offsetBy: offset)
                    let end = text.index(start, offsetBy: length)
                    results.append(DetectedEntity(type: .name, value: String(text[start..<end]),
                                                  confidence: 0.6, source: .nlTagger, locus: .text(start..<end)))
                }
            }
            guard lineEnd < text.endIndex else { break }
            lineStart = text.index(after: lineEnd)
        }
        return results
    }

    private static let carrierPrefix = "I spoke with "
    private static let carrierSuffix = " yesterday."

    /// True when the line holds two or more runs of non-whitespace. Stops at the second one rather
    /// than splitting, because this runs on every line of every page.
    private static func hasTwoWords(_ line: Substring) -> Bool {
        var words = 0
        var inWord = false
        for character in line {
            if character.isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
                if words == 2 { return true }
            }
        }
        return false
    }

    /// Tag names in `tagString`, but emit ranges/values against `sourceString` (same length, 1:1
    /// characters), so a normalized copy's hits map back to the original text.
    private func tagNames(tagString: String, sourceString: String, using tagger: NLTagger) -> [DetectedEntity] {
        var results: [DetectedEntity] = []
        for (type, range) in Self.taggedRanges(in: tagString, using: tagger) {
            let lower = tagString.distance(from: tagString.startIndex, to: range.lowerBound)
            let upper = tagString.distance(from: tagString.startIndex, to: range.upperBound)
            guard let sourceLower = sourceString.index(sourceString.startIndex, offsetBy: lower, limitedBy: sourceString.endIndex),
                  let sourceUpper = sourceString.index(sourceString.startIndex, offsetBy: upper, limitedBy: sourceString.endIndex) else {
                continue
            }
            let sourceRange = sourceLower..<sourceUpper
            results.append(DetectedEntity(type: type, value: String(sourceString[sourceRange]),
                                          confidence: 0.6, source: .nlTagger, locus: .text(sourceRange)))
        }
        return results
    }

    /// The tagger is passed in, not built here. Every caller runs this in a loop, so building one
    /// per call is what made this the slowest layer in the text stage.
    private static func taggedRanges(in text: String, using tagger: NLTagger)
        -> [(EntityType, Range<String.Index>)] {
        tagger.string = text
        var found: [(EntityType, Range<String.Index>)] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if let type = category(for: tag) { found.append((type, range)) }
            return true
        }
        return found
    }

    /// Title-case each word (first letter upper, rest lower), preserving length + a 1:1 character
    /// mapping so offsets still line up with the original (skips any case fold that changes length).
    private static func titleCased(_ text: String) -> String {
        var result = ""
        var atWordStart = true
        for character in text {
            if character.isLetter {
                let mapped = atWordStart ? character.uppercased() : character.lowercased()
                result.append(mapped.count == 1 ? mapped : String(character))
                atWordStart = false
            } else {
                result.append(character)
                atWordStart = !character.isNumber
            }
        }
        return result
    }

    private static func category(for tag: NLTag?) -> EntityType? {
        switch tag {
        case .personalName: .name
        case .placeName: .other("PLACE")
        case .organizationName: .other("ORG")
        default: nil
        }
    }
}
