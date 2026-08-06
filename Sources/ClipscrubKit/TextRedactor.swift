import Foundation

public struct RedactionResult: Sendable {
    /// Source text with every enabled entity replaced by its token.
    public let redactedText: String
    /// The entities that were applied, each carrying its assigned `tokenLabel`.
    public let entities: [DetectedEntity]
    /// Found and left in the text BY DESIGN — the clinical codes, and only those.
    ///
    /// Held separately rather than dropped. A caller that only receives what was removed cannot
    /// tell "we left the CPT code in on purpose" from "we never saw it", so it cannot say either —
    /// and the reader learns which it was by sending the document.
    ///
    /// Deliberately not "everything still in the text". A reader who switches an SSN off in review
    /// also leaves it in, and reporting that as a policy decision would describe an accident as an
    /// intention. Only a `flag` rule earns this list.
    public let flagged: [DetectedEntity]

    public init(redactedText: String, entities: [DetectedEntity], flagged: [DetectedEntity] = []) {
        self.redactedText = redactedText
        self.entities = entities
        self.flagged = flagged
    }

    /// JSON-serialisable entity list for reports, in reading order.
    public func reports(over sourceText: String) -> [EntityReport] {
        entityReports(for: entities, in: sourceText)
    }
}

/// Replaces detected spans with tokens.
///
/// - Redact mode: generic typed tokens (`[NAME_1]`, `[MRN_1]`). The same (type, value) maps to
///   the same token within a document; the index is a per-document counter NOT derived from the
///   value (Safe Harbor). Original values are discarded from the output.
/// - Pseudonymise mode: stable keyed tokens from the `Pseudonymiser` (`NAME_9F3A`), consistent
///   within AND across documents. Falls back to redact tokens if no pseudonymiser is supplied
///   (fail-safe — never block redaction).
public struct TextRedactor: Sendable {
    public init() {}

    public func redact(
        _ text: String,
        entities: [DetectedEntity],
        mode: OutputMode = .redact,
        pseudonymiser: Pseudonymiser? = nil
    ) -> RedactionResult {
        struct Segment {
            let start: Int
            let end: Int
            let token: String
        }

        // Only enabled, text-locus entities participate.
        let active = entities
            .filter { $0.isEnabled && $0.isTextLocus }
            .compactMap { entity -> (DetectedEntity, Int, Int)? in
                guard let offsets = entity.offsets(in: text) else { return nil }
                return (entity, offsets.start, offsets.start + offsets.length)
            }
            .sorted { $0.1 < $1.1 } // reading order → NAME_1 before NAME_2

        var counters: [String: Int] = [:]        // token prefix → next index (redact mode)
        var tokenForValue: [String: String] = [:] // "PREFIX\0value" → token (intra-doc consistency)
        var labeled: [DetectedEntity] = []
        var segments: [Segment] = []

        for (entity, start, end) in active {
            let prefix = entity.type.tokenPrefix
            let cacheKey = "\(prefix)\u{0}\(entity.value)"
            let token: String
            if let existing = tokenForValue[cacheKey] {
                token = existing
            } else {
                token = makeToken(for: entity, prefix: prefix, mode: mode,
                                  pseudonymiser: pseudonymiser, counters: &counters)
                tokenForValue[cacheKey] = token
            }
            var stamped = entity
            stamped.tokenLabel = token
            labeled.append(stamped)
            segments.append(Segment(start: start, end: end, token: token))
        }

        // Apply right-to-left so earlier (lower) offsets stay valid on the mutated copy. The
        // engine guarantees disjoint spans; this loop additionally skips any span that overlaps
        // an already-applied one, so a stray overlap can never corrupt the offset math.
        var result = text
        var appliedLowerBound = Int.max
        for segment in segments.sorted(by: { $0.start > $1.start }) {
            guard segment.end <= appliedLowerBound else { continue }
            let lower = result.index(result.startIndex, offsetBy: segment.start)
            let upper = result.index(result.startIndex, offsetBy: segment.end)
            result.replaceSubrange(lower..<upper, with: segment.token)
            appliedLowerBound = segment.start
        }

        return RedactionResult(
            redactedText: result,
            entities: labeled,
            flagged: entities.filter { $0.disposition == .flag && !$0.isEnabled && $0.isTextLocus }
        )
    }

    private func makeToken(
        for entity: DetectedEntity,
        prefix: String,
        mode: OutputMode,
        pseudonymiser: Pseudonymiser?,
        counters: inout [String: Int]
    ) -> String {
        if mode == .pseudonymise, let pseudonymiser {
            return pseudonymiser.token(for: entity.value, type: entity.type)
        }
        let index = (counters[prefix] ?? 0) + 1
        counters[prefix] = index
        return "[\(prefix)_\(index)]"
    }
}

/// Convenience wiring of the default text detector stack + text redactor.
public struct RedactionPipeline: Sendable {
    private let engine: DetectionEngine
    private let redactor = TextRedactor()

    public init(engine: DetectionEngine) {
        self.engine = engine
    }

    /// Layers 1–3 — the deterministic floor of every stack: data detectors + regex ruleset + NER +
    /// name gazetteer. Same order in both factories so token numbering can never drift between them.
    private static func deterministicDetectors() throws -> [any EntityDetector] {
        [
            DataDetectorDetector(),
            try RegexRulesetDetector(ruleset: try Ruleset.bundled()),
            DelimitedFieldDetector(),
            NameEntityDetector(),
            CommonNameDetector(),
        ]
    }

    /// Default layers 1–3 stack (no LLM): data detectors + regex ruleset + NER.
    public static func makeDefault() throws -> RedactionPipeline {
        RedactionPipeline(engine: DetectionEngine(detectors: try deterministicDetectors()))
    }

    /// Layers 1–3 plus the Foundation Models semantic tier when a compatible on-device model is
    /// available. On an SDK without FoundationModels, on macOS < 26, or with Apple Intelligence
    /// off this is identical to `makeDefault()` — the tier is additive and never gates the
    /// deterministic floor.
    public static func makeWithModel() throws -> RedactionPipeline {
        var detectors = try deterministicDetectors()
        #if canImport(FoundationModels)
        if #available(macOS 26, *), FoundationModelDetector.isAvailable {
            detectors.append(FoundationModelDetector())
        }
        #endif
        return RedactionPipeline(engine: DetectionEngine(detectors: detectors))
    }

    public func detect(text: String) async throws -> [DetectedEntity] {
        try await engine.detect(in: .text(text))
    }

    public func run(
        text: String,
        mode: OutputMode = .redact,
        pseudonymiser: Pseudonymiser? = nil
    ) async throws -> RedactionResult {
        let entities = try await engine.detect(in: .text(text))
        return redactor.redact(text, entities: entities, mode: mode, pseudonymiser: pseudonymiser)
    }
}
