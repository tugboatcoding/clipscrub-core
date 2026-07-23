import Foundation

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
        for detector in detectors {
            // Per-detector isolation is a hard design invariant: the deterministic layers (1–3) are
            // the redaction floor and MUST survive a failure in any single layer — above all the
            // optional Foundation Models pass, whose `respond(...)` throws readily (context-window,
            // guardrail, generation error). One throwing layer must never zero out the others, or a
            // fully-detectable page can silently produce no redaction. (Cancellation still propagates.)
            do {
                all += try await detector.detect(in: input)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        guard case let .text(text) = input else { return all }
        return Self.resolveOverlaps(all, in: text)
    }

    private struct Interval {
        let entity: DetectedEntity
        let start: Int
        let end: Int
    }

    /// Reduce to disjoint spans, preferring higher confidence then longer coverage.
    static func resolveOverlaps(_ entities: [DetectedEntity], in text: String) -> [DetectedEntity] {
        let intervals: [Interval] = entities
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
        for candidate in intervals {
            guard let last = kept.last, candidate.start < last.end else {
                kept.append(candidate)
                continue
            }
            if prefers(candidate, over: last) {
                kept[kept.count - 1] = candidate
            }
            // else: drop the overlapping candidate, keep the incumbent
        }
        return kept.map(\.entity)
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
