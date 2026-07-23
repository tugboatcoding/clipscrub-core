import AppKit
import Foundation

/// Redacts a *formatted* document so a redacted `.rtf` or `.docx` keeps its formatting — only the
/// identifier spans turn into tokens. It reuses the tokens the text pipeline already assigned, so
/// pass in `RedactionResult.entities` (each entity carries its own `tokenLabel`).
public enum AttributedRedactor {
    public static func apply(_ entities: [DetectedEntity], to attributed: NSAttributedString) -> NSAttributedString {
        let text = attributed.string
        // (nsRange, token) for each enabled text-locus entity that got a token.
        var spans: [(range: NSRange, token: String)] = []
        for entity in entities {
            guard entity.isEnabled, let token = entity.tokenLabel, let offsets = entity.offsets(in: text) else { continue }
            guard let start = text.index(text.startIndex, offsetBy: offsets.start, limitedBy: text.endIndex),
                  let end = text.index(start, offsetBy: offsets.length, limitedBy: text.endIndex) else { continue }
            spans.append((NSRange(start..<end, in: text), token))
        }

        let mutable = NSMutableAttributedString(attributedString: attributed)
        // Apply right-to-left so earlier offsets stay valid; skip any span overlapping an applied one.
        var appliedLowerBound = Int.max
        for span in spans.sorted(by: { $0.range.location > $1.range.location }) {
            guard span.range.location + span.range.length <= appliedLowerBound, span.range.location < mutable.length else { continue }
            let attributes = mutable.attributes(at: span.range.location, effectiveRange: nil)
            mutable.replaceCharacters(in: span.range, with: NSAttributedString(string: span.token, attributes: attributes))
            appliedLowerBound = span.range.location
        }
        return mutable
    }
}
