import Foundation

/// Reads a JSON object and identifies values by the KEY THEY SIT UNDER.
///
/// `DelimitedFieldDetector` makes the argument in full: some identifiers have no shape to match, so
/// a regex is the wrong instrument and the field name is the signal. That argument does not stop at
/// CSV. The same export arrives as JSON at least as often, and until this existed the name on the
/// key was read by nothing:
///
///     {"mrn": "88214309"}   →   {"mrn": "88214309"}
///
/// Eight digits, no shape, and no literal "MRN" beside it for the labelled rule in `ruleset.json`
/// to anchor on. So a medical record number, which Safe Harbor names as a direct identifier, came
/// through the deterministic layers untouched. The same record as a `.csv` with an `mrn` header was
/// handled correctly, because there the field name was already being read.
///
/// Deliberately JSON, not `key: value` generally. A bare `Street: where I grew up` in prose is the
/// same shape as a field and is not one, and this detector has no equivalent of the sibling's
/// "several columns, rows that agree" guard to tell them apart. A quoted key followed by a colon is
/// unambiguous, so that is the whole of what is matched here. Loose `key: value` text is out of
/// scope on purpose.
public struct JSONFieldDetector: EntityDetector {
    public let source: DetectionSource = .structuredField

    /// `"key" :` — the key and where its value begins. What the value IS is decided by walking it,
    /// not by a second alternation in this pattern: a value can be a scalar or an ARRAY of them,
    /// and `"mrn": ["88214309"]` is a real export shape that a scalar-only pattern reads as absent.
    ///
    /// The key group tolerates the punctuation real exports use (`patient_id`, `member-id`,
    /// `Medical Record No`) because `normalise` strips it back out anyway.
    private static let key: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\"([A-Za-z0-9_ .-]{1,64})\"\\s*:\\s*"
    )

    /// One JSON scalar. Group 1 lands INSIDE the quotes, so `"mrn": "[MRN_1]"` stays valid JSON
    /// after substitution. Group 2 is an unquoted number.
    ///
    /// `[^"\\]*(?:\\.[^"\\]*)*` is the standard escaped-string body: without it a value containing
    /// `\"` ends the match early and the rest of the value is left in the clear.
    ///
    /// Substituting an unquoted number in place DOES produce invalid JSON — `{"mrn": 88214309}`
    /// becomes `{"mrn": [MRN_1]}`. That is a deliberate trade and it is the safe direction: the
    /// alternative is passing the identifier through untouched. Redaction is this tool's contract,
    /// re-parseability is not.
    private static let scalar: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\"([^\"\\\\]*(?:\\\\.[^\"\\\\]*)*)\"|(-?[0-9]+(?:\\.[0-9]+)?)"
    )

    public init() {}

    public func detect(in input: DetectionInput) async throws -> [DetectedEntity] {
        guard case let .text(text) = input, !text.isEmpty else { return [] }
        guard let key = Self.key, let scalar = Self.scalar else { return [] }

        let whole = NSRange(text.startIndex..., in: text)
        return key.matches(in: text, range: whole).flatMap { match -> [DetectedEntity] in
            guard let keyRange = Range(match.range(at: 1), in: text),
                  let column = DelimitedFieldDetector.columns[DelimitedFieldDetector.normalise(String(text[keyRange]))],
                  let valueStart = Range(match.range, in: text)?.upperBound,
                  valueStart < text.endIndex
            else { return [] }

            let spans: [Range<String.Index>]
            if text[valueStart] == "[" {
                // The array's own elements, one level down and no deeper. A nested object or array
                // is stepped OVER rather than swept: in `"mrn": [{"chart": "A1"}]` the value belongs
                // to `chart`, not to `mrn`, and the key pass reaches it there on its own.
                //
                // Stepping over one element must not cost the others. Bailing on the whole key at
                // the first nested bracket dropped `"88214309"` from
                // `{"mrn": ["88214309", ["x"]]}` — a value sitting in plain sight beside one this
                // detector had no opinion about.
                spans = Self.elements(of: valueStart, in: text)
            } else {
                // One scalar, anchored: the value is what sits AT valueStart, not the next scalar
                // that happens to appear downstream. `"mrn": {}` matches nothing and is skipped.
                spans = Self.scalars(scalar, in: valueStart..<text.endIndex, of: text, anchored: true)
            }

            return spans.compactMap { range -> DetectedEntity? in
                // Empty covers `""`: a zero-width span gives the redactor nothing to tokenise.
                guard !range.isEmpty, DelimitedFieldDetector.shapeAllows(column, value: text[range]) else { return nil }
                return DetectedEntity(
                    type: column.type,
                    value: String(text[range]),
                    confidence: 0.9,
                    source: .structuredField,
                    locus: .text(range),
                    disposition: column.disposition
                )
            }
        }
    }

    /// The immediate scalar elements of the array opening at `open`.
    ///
    /// Walks once, tracking how deep it is inside nested brackets. A string or number found at
    /// depth zero is an element of THIS array. Anything deeper belongs to a structure of its own
    /// and is passed over, without ending the walk. An array that never closes yields nothing —
    /// there is no way to know where the value stopped, so nothing is claimed for the key.
    private static func elements(of open: String.Index, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var index = text.index(after: open)
        var depth = 0

        while index < text.endIndex {
            switch text[index] {
            case "]" where depth == 0:
                return found
            case "]", "}":
                depth -= 1
                index = text.index(after: index)
            case "[", "{":
                depth += 1
                index = text.index(after: index)
            case "\"":
                let (interior, next) = Self.endOfString(from: index, in: text)
                if depth == 0, let interior { found.append(interior) }
                index = next
            case let character where depth == 0 && (character == "-" || character.isNumber):
                let start = index
                while index < text.endIndex, text[index] == "-" || text[index] == "." || text[index].isNumber {
                    index = text.index(after: index)
                }
                found.append(start..<index)
            default:
                index = text.index(after: index)
            }
        }
        return []   // unterminated
    }

    /// The interior of the string starting at the quote `open` (nil if it never closes), and the
    /// index just past its closing quote. `\"` does not end a string, so the tail of a value
    /// containing one is not left in the clear.
    private static func endOfString(from open: String.Index, in text: String) -> (Range<String.Index>?, String.Index) {
        var index = text.index(after: open)
        let start = index
        while index < text.endIndex {
            if text[index] == "\\" {
                index = text.index(after: index)
                guard index < text.endIndex else { break }
            } else if text[index] == "\"" {
                return (start..<index, text.index(after: index))
            }
            index = text.index(after: index)
        }
        return (nil, text.endIndex)
    }

    private static func scalars(
        _ pattern: NSRegularExpression,
        in span: Range<String.Index>,
        of text: String,
        anchored: Bool = false
    ) -> [Range<String.Index>] {
        guard !span.isEmpty else { return [] }
        let range = NSRange(span, in: text)
        let matches = anchored
            ? pattern.firstMatch(in: text, options: [.anchored], range: range).map { [$0] } ?? []
            : pattern.matches(in: text, range: range)
        return matches.compactMap { Range($0.range(at: 1), in: text) ?? Range($0.range(at: 2), in: text) }
    }
}
