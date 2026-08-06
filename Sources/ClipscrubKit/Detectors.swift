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
        var results = tagNames(tagString: text, sourceString: text)

        // NLTagger's name model leans on capitalization, so ALL-CAPS ("JANICE") and lowercase names
        // are missed. Re-run on a length-preserving Title-Cased copy and map the spans back.
        // This over-flags some prose ("fox trot dippy dappy" reads as a name), but that is the SAFE
        // direction for a redactor: an over-redacted word is recoverable, a leaked name is not. The
        // name-instability the user hit lived in the LLM tier, which the DetectionEngine gate trims.
        let normalized = Self.titleCased(text)
        if normalized != text {
            Self.merge(tagNames(tagString: normalized, sourceString: text), into: &results)
        }

        Self.merge(carriedLineNames(in: text), into: &results)
        return results
    }

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
    private func carriedLineNames(in text: String) -> [DetectedEntity] {
        var results: [DetectedEntity] = []
        var lineStart = text.startIndex
        while true {
            // Any newline ends a line, not just "\n". Swift reads CRLF as ONE character, so looking
            // for "\n" finds nothing in a Windows document and the whole file arrives here as a
            // single line — which is every document this pass exists to help, wrapped in one
            // useless sentence.
            let lineEnd = text[lineStart...].firstIndex(where: \.isNewline) ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            if !line.isEmpty {
                let carried = Self.carrierPrefix + line + Self.carrierSuffix
                let lineLower = carried.index(carried.startIndex, offsetBy: Self.carrierPrefix.count)
                let lineUpper = carried.index(lineLower, offsetBy: line.count)
                for (type, range) in Self.taggedRanges(in: carried)
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

    /// Tag names in `tagString`, but emit ranges/values against `sourceString` (same length, 1:1
    /// characters), so a normalized copy's hits map back to the original text.
    private func tagNames(tagString: String, sourceString: String) -> [DetectedEntity] {
        var results: [DetectedEntity] = []
        for (type, range) in Self.taggedRanges(in: tagString) {
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

    private static func taggedRanges(in text: String) -> [(EntityType, Range<String.Index>)] {
        let tagger = NLTagger(tagSchemes: [.nameType])
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
