import Foundation

/// Catches standalone and ALL-CAPS first names ("JANICE", "MARC") that the statistical name model
/// (`NLTagger`) misses because it relies on sentence context and capitalisation. It matches whole
/// words against a bundled list of common first names, case-insensitively, at a modest confidence —
/// so a false positive is easy for callers to filter out.
///
/// The name list lives in `Resources/given-names.json`, keyed by language ("en", "es", "ja", …), so
/// a new locale is a data edit — add a key — not a code change. All languages are loaded together;
/// the keys only organise the file.
public struct CommonNameDetector: EntityDetector {
    public let source: DetectionSource = .nlTagger

    public init() {}

    public func detect(in input: DetectionInput) async throws -> [DetectedEntity] {
        guard case let .text(text) = input, !text.isEmpty else { return [] }
        var results: [DetectedEntity] = []
        let nsRange = NSRange(text.startIndex..., in: text)
        Self.wordRegex.enumerateMatches(in: text, range: nsRange) { match, _, _ in
            guard let match, let range = Range(match.range, in: text) else { return }
            if Self.names.contains(String(text[range]).lowercased()) {
                results.append(DetectedEntity(type: .name, value: String(text[range]),
                                              confidence: 0.5, source: .nlTagger, locus: .text(range)))
            }
        }
        return results
    }

    private static let wordRegex = try! NSRegularExpression(pattern: "\\b\\p{L}[\\p{L}'\\-]+\\b")

    /// The union of every language's names, lower-cased for case-insensitive lookup. The file is a
    /// package resource, so a missing/corrupt file is a build error, not a runtime condition — we
    /// fail loudly rather than silently detect no names (which would under-redact).
    static let names: Set<String> = {
        guard let url = Bundle.module.url(forResource: "given-names", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let byLanguage = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            preconditionFailure("given-names.json missing or unreadable in the ClipscrubKit bundle")
        }
        return Set(byLanguage.values.joined().map { $0.lowercased() })
    }()
}
