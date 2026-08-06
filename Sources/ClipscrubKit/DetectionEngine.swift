import Foundation

public enum DetectionEngineError: Error, Sendable {
    /// No detector completed, so nothing looked at the input. Distinct from "every detector ran and
    /// found nothing", which is an empty result and a success.
    case noDetectorCompleted
}

/// Runs every configured detector over one input and merges the results into a single
/// list of **disjoint** spans, so the redactor can tokenise cleanly.
///
/// Overlap policy (text): when two spans overlap, keep the higher-confidence one
/// (tie → the longer span). This resolves e.g. an `NLTagger` first-name detected
/// inside an email that `NSDataDetector` already matched — the email wins.
public struct DetectionEngine: Sendable {
    private let detectors: [any EntityDetector]

    public init(detectors: [any EntityDetector]) {
        self.detectors = detectors
    }

    public func detect(in input: DetectionInput) async throws -> [DetectedEntity] {
        var all: [DetectedEntity] = []
        var completed = 0
        for detector in detectors {
            // Per-detector isolation is a hard design invariant: the deterministic layers (1–3) are
            // the redaction floor and MUST survive a failure in any single layer — above all the
            // optional Foundation Models pass, whose `respond(...)` throws readily (context-window,
            // guardrail, generation error). One throwing layer must never zero out the others, or a
            // fully-detectable page can silently produce no redaction. (Cancellation still propagates.)
            do {
                all += try await detector.detect(in: input)
                completed += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        // Isolating each layer must not extend to isolating ALL of them. With every detector down —
        // or none configured — `all` is empty for the same reason a clean page is, and the caller
        // cannot tell "checked, nothing here" from "nothing checked it". That gap emits the input
        // unchanged as redacted output, so it is a failure, not a result.
        guard completed > 0 else { throw DetectionEngineError.noDetectorCompleted }
        guard case let .text(text) = input else { return all }
        return Self.resolveOverlaps(Self.gateModelFindings(all), in: text)
    }

    /// Confidence floor for the optional Foundation Models tier (layer 4). The deterministic
    /// layers 1–3 are the redaction floor and are never gated. Conservative on purpose: only the
    /// model's genuinely uncertain guesses drop, so recall on real PII holds.
    static let modelConfidenceFloor = 0.5

    /// The Foundation Models tier is the one non-deterministic layer, so it is also the one that
    /// over-redacts on context — labelling ordinary words as PHI. This trims ONLY that tier, in two
    /// safe ways, so the deterministic floor and the real PII the model catches both survive.
    static func gateModelFindings(_ entities: [DetectedEntity]) -> [DetectedEntity] {
        // Spans any deterministic layer already flagged. A model-only generic OTHER over one of
        // these is redundant; over anything else it is an unanchored guess.
        let deterministicRanges: [Range<String.Index>] = entities.compactMap { entity in
            guard entity.source != .foundationModel, case let .text(range) = entity.locus else { return nil }
            return range
        }
        return entities.filter { entity in
            guard entity.source == .foundationModel else { return true } // floor untouched
            if entity.confidence < modelConfidenceFloor { return false }
            // Real PII is never made of only function words, so the model tagging "hey my" as a
            // NAME is always a hallucination. Suppress it — but never when a token is a known given
            // name, so real names that double as common words ("Will", "May") still redact.
            if isAllFunctionWords(entity.value) { return false }
            // The generic OTHER bucket carries no category meaning — it is where context-sensitive
            // over-flagging lands. Keep it only when a deterministic layer covered the same span.
            if entity.type.identifier == "other" {
                guard case let .text(range) = entity.locus else { return false }
                return deterministicRanges.contains { $0.overlaps(range) }
            }
            return true
        }
    }

    /// True when every word in `value` is a common English function word and none is a known given
    /// name. The model's confidence is unreliable here (it rates "hey my" as a NAME at 1.0), so this
    /// structural test — not confidence — is what stops function-word phantoms. Gazetteer-guarded so
    /// it can only trim non-identifying filler, never a real name.
    static func isAllFunctionWords(_ value: String) -> Bool {
        // Any digit means an identifier component ("ID A1234567"), never pure filler.
        if value.contains(where: \.isNumber) { return false }
        let words = value.split { !$0.isLetter && $0 != "'" }.map { $0.lowercased() }
        guard !words.isEmpty else { return false }
        if words.contains(where: { CommonNameDetector.names.contains($0) }) { return false }
        return words.allSatisfy { functionWords.contains($0) }
    }

    /// Curated non-identifier words: articles, pronouns, prepositions, conjunctions, auxiliaries,
    /// interjections. Deliberately excludes words that are also common names — both English (will,
    /// may, mark, grace, rose, dawn, hope, faith) and short romanized names (so, an, he, we, no, hi) —
    /// so those still redact. The gazetteer check in `isAllFunctionWords` is a second guard for
    /// names that slip in.
    private static let functionWords: Set<String> = [
        "a", "the", "this", "that", "these", "those", "here", "there", "then",
        "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did", "has", "have", "had",
        "i", "you", "she", "they", "it", "me", "us", "them", "him",
        "my", "your", "our", "their", "his", "her", "its", "mine", "yours", "ours", "theirs",
        "of", "to", "in", "on", "at", "for", "with", "from", "by", "as", "about", "into", "onto", "over",
        "and", "or", "but", "if", "than", "because", "while", "when", "where", "which", "who", "whom",
        "hey", "hello", "yeah", "yep", "okay", "please", "thanks", "thank", "yes", "not",
        "ssn", "dob", "phone", "email", "address", "name",
    ]

    private struct Interval {
        let entity: DetectedEntity
        let start: Int
        let end: Int
    }

    /// Reduce to disjoint spans, preferring higher confidence then longer coverage. When the winner
    /// covers only part of the loser, the rest of the loser is kept as a span of its own — a name
    /// model often runs its span one word into a following date, and dropping the loser whole
    /// would uncover the name.
    static func resolveOverlaps(_ entities: [DetectedEntity], in text: String) -> [DetectedEntity] {
        var pending: [Interval] = entities
            .compactMap { entity in
                guard let offsets = entity.offsets(in: text) else { return nil }
                return Interval(entity: entity, start: offsets.start, end: offsets.start + offsets.length)
            }
            .filter { $0.end > $0.start }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                if lhs.end != rhs.end { return lhs.end > rhs.end }          // longer first
                return lhs.entity.confidence > rhs.entity.confidence
            }

        var kept: [Interval] = []
        var next = 0
        while next < pending.count {
            let candidate = pending[next]
            next += 1
            guard let incumbent = kept.last, candidate.start < incumbent.end else {
                kept.append(candidate)
                continue
            }
            // Already inside a kept span, so it is redacted either way.
            if incumbent.start <= candidate.start && candidate.end <= incumbent.end { continue }
            if prefers(candidate, over: incumbent) {
                if let remainder = clipping(incumbent, from: incumbent.start, to: candidate.start, in: text) {
                    kept[kept.count - 1] = remainder
                } else {
                    kept.removeLast()
                }
                kept.append(candidate)
            } else if let remainder = clipping(candidate, from: incumbent.end, to: candidate.end, in: text) {
                // Back into the queue in start order, not straight onto `kept` — the loop only ever
                // compares against the last kept span, so a span that starts later than the one
                // after it would make the next comparison meaningless.
                let position = pending[next...].firstIndex { $0.start > remainder.start } ?? pending.endIndex
                pending.insert(remainder, at: position)
            }
        }
        return kept.map(\.entity)
    }

    /// The part of a span the winner does not cover, as a span of its own. Surrounding whitespace is
    /// dropped so the leftover is the words themselves. Nil when nothing is left to keep.
    private static func clipping(_ interval: Interval, from lower: Int, to upper: Int, in text: String) -> Interval? {
        guard lower < upper else { return nil }
        var start = text.index(text.startIndex, offsetBy: lower)
        var end = text.index(text.startIndex, offsetBy: upper)
        while start < end, text[start].isWhitespace { start = text.index(after: start) }
        while start < end, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
        guard start < end else { return nil }

        let entity = interval.entity
        let clipped = DetectedEntity(
            type: entity.type,
            value: String(text[start..<end]),
            confidence: entity.confidence,
            source: entity.source,
            locus: .text(start..<end),
            // A leftover of a flag span is still a flag. Dropping it here would turn the remainder
            // back into something the redactor removes.
            disposition: entity.disposition
        )
        return Interval(entity: clipped,
                        start: text.distance(from: text.startIndex, to: start),
                        end: text.distance(from: text.startIndex, to: end))
    }

    /// Prefer higher confidence; tie → longer span.
    private static func prefers(_ candidate: Interval, over incumbent: Interval) -> Bool {
        // Never drop a span that fully CONTAINS the candidate — keeping the shorter one would leave the
        // container's tail un-redacted (e.g. an email detected inside a URL → the URL's path leaks).
        // Redact the larger (the union); safe direction for a redactor.
        if incumbent.start <= candidate.start && candidate.end <= incumbent.end { return false }
        if candidate.entity.confidence != incumbent.entity.confidence {
            return candidate.entity.confidence > incumbent.entity.confidence
        }
        return (candidate.end - candidate.start) > (incumbent.end - incumbent.start)
    }
}
