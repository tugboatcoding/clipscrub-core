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
                        locus: .text(range)
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
        let normalized = Self.titleCased(text)
        if normalized != text {
            for entity in tagNames(tagString: normalized, sourceString: text) {
                guard case let .text(newRange) = entity.locus else { continue }
                let overlapsExisting = results.contains {
                    if case let .text(existing) = $0.locus { return existing.overlaps(newRange) }
                    return false
                }
                if !overlapsExisting { results.append(entity) }
            }
        }
        return results
    }

    /// Tag names in `tagString`, but emit ranges/values against `sourceString` (same length, 1:1
    /// characters), so a normalized copy's hits map back to the original text.
    private func tagNames(tagString: String, sourceString: String) -> [DetectedEntity] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = tagString
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        var results: [DetectedEntity] = []
        tagger.enumerateTags(in: tagString.startIndex..<tagString.endIndex, unit: .word,
                             scheme: .nameType, options: options) { tag, range in
            guard let type = Self.category(for: tag) else { return true }
            let lower = tagString.distance(from: tagString.startIndex, to: range.lowerBound)
            let upper = tagString.distance(from: tagString.startIndex, to: range.upperBound)
            guard let sourceLower = sourceString.index(sourceString.startIndex, offsetBy: lower, limitedBy: sourceString.endIndex),
                  let sourceUpper = sourceString.index(sourceString.startIndex, offsetBy: upper, limitedBy: sourceString.endIndex) else {
                return true
            }
            let sourceRange = sourceLower..<sourceUpper
            results.append(DetectedEntity(type: type, value: String(sourceString[sourceRange]),
                                          confidence: 0.6, source: .nlTagger, locus: .text(sourceRange)))
            return true
        }
        return results
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
