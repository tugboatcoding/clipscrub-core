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
        return Self.resolveOverlaps(Self.gateModelFindings(all, in: text), in: text)
    }

    /// Confidence floor for the optional Foundation Models tier (layer 4). The deterministic
    /// layers 1–3 are the redaction floor and are never gated. Conservative on purpose: only the
    /// model's genuinely uncertain guesses drop, so recall on real PII holds.
    static let modelConfidenceFloor = 0.5

    /// The Foundation Models tier is the one non-deterministic layer, so it is also the one that
    /// over-redacts on context — labelling ordinary words as PHI. This trims ONLY that tier, so the
    /// deterministic floor and the real PII the model catches both survive.
    ///
    /// Measured shapes this is written against, all from real runs: `PHQ-9 score was 14.` came back
    /// as two findings under an invented `PHIFinding` category, `Sessions began in 2026.` tagged
    /// `Sessions` as a NAME, and `Beck Depression Inventory-II administered.` arrived as one NAME
    /// spanning the whole sentence. None of those is a person and none was caught by confidence —
    /// the model rated them as highly as it rates real names. So every rule here is structural.
    ///
    /// `text` is what a truncated span is re-anchored against. Pass it wherever it is available. With
    /// no text a value that reads as a name followed by prose is kept whole rather than dropped,
    /// because over-redacting the prose is recoverable and dropping the name is a leak.
    static func gateModelFindings(_ entities: [DetectedEntity], in text: String? = nil) -> [DetectedEntity] {
        // Spans any deterministic layer already flagged. A model finding over one of these is
        // corroborated — some rule, gazetteer or NER pass reached the same characters on its own.
        let deterministicRanges: [Range<String.Index>] = entities.compactMap { entity in
            guard entity.source != .foundationModel, case let .text(range) = entity.locus else { return nil }
            return range
        }
        // Two strengths of corroboration, for two different questions. `isCovered` asks whether some
        // other layer accounted for this whole span, which is what a suspect finding has to clear —
        // anything sticking out past the deterministic span is the model's own guess, and for a
        // category the prompt never offered there is no reason to trust it. `overlaps` asks only
        // whether something is there at all, which is the right test for a name the model may
        // legitimately have read further than the rules did.
        func isCovered(_ entity: DetectedEntity) -> Bool {
            guard case let .text(range) = entity.locus else { return false }
            return deterministicRanges.contains { $0.lowerBound <= range.lowerBound && range.upperBound <= $0.upperBound }
        }
        func overlapsFloor(_ entity: DetectedEntity) -> Bool {
            guard case let .text(range) = entity.locus else { return false }
            return deterministicRanges.contains { $0.overlaps(range) }
        }

        return entities.compactMap { entity in
            guard entity.source == .foundationModel else { return entity } // floor untouched
            if entity.confidence < modelConfidenceFloor { return nil }
            // Real PII is never made of only function words, so the model tagging "hey my" as a
            // NAME is always a hallucination. Suppress it — but never when a token is a known given
            // name, so real names that double as common words ("Will", "May") still redact.
            if isAllFunctionWords(entity.value) { return nil }
            // The generic OTHER bucket carries no category meaning — it is where context-sensitive
            // over-flagging lands. Keep it only when a deterministic layer covered the same span.
            if entity.type.identifier == "other" { return overlapsFloor(entity) ? entity : nil }
            // A label the prompt never offered means the model could not pick a category. That is a
            // reason to distrust the LABEL, not the value — one run filed a real Vietnamese name
            // under `PHIFinding`, and dropping every invented label loses it. So the value is judged
            // on its own shape, by the same tests a NAME gets.
            let judgeOnShape = entity.type == .name || isOffScriptCategory(entity.type)
            // An instrument code reads exactly like an all-caps surname, and the model types both as
            // NAME. A short bare number is the same story — `Sessions began in 2026.` came back with
            // 2026 as a NAME, and a year identifies nobody. Corroboration separates them:
            // `Patient SMITH arrived.` is caught by the name layers on their own, `Seen by MMSE
            // today.` is caught by nothing. Any deterministic span touching the value is enough,
            // because `SMITH` and `LEE` are surnames the gazetteer does not hold and an OCR slice
            // can leave the floor's span a character short of the model's.
            if judgeOnShape, !overlapsFloor(entity),
               isInstrumentAcronym(entity.value) || isShortBareNumber(entity.value) { return nil }
            // A name followed by ordinary prose means the model ran its span past the identifier.
            // Cut it back to the part that can still be a name. Two or more words is a name being
            // read too far, so it is kept — dropping it is how `Sarah Connor met the therapist`
            // ships a surname in the clear. One word with nothing on the floor beside it is the
            // shape of `Rogerian therapy`, and that is dropped.
            if let head = leadingNameRun(of: entity.value) {
                guard let text, let trimmed = truncating(entity, to: head, in: text) else { return entity }
                if head.contains(where: \.isWhitespace) { return trimmed }
                return overlapsFloor(trimmed) ? trimmed : nil
            }
            return entity
        }
    }

    /// True for a category the prompt did not offer. `llm-prompt.json` is the contract the model was
    /// given, so a label outside it (runs produced `PHI` and `PHIFinding`) is the model inventing a
    /// category rather than reporting one. `OTHER` is on the prompt and has its own rule.
    static func isOffScriptCategory(_ type: EntityType) -> Bool {
        guard case let .other(subtype) = type, type.identifier != "other" else { return false }
        return !LLMPrompt.offeredCategories.contains(subtype.uppercased())
    }

    /// True for `MMSE`, `PHQ-9`, `GAD-7` — two to five capitals with an optional one or two digit
    /// suffix. The digit bound is what keeps a real identifier out: `HPX-4471209` has seven digits,
    /// is model-only (no deterministic layer reaches it) and would be lost by any rule that simply
    /// treats a digit in a name as disqualifying. Gazetteer-guarded so `SARAH` is never caught.
    static func isInstrumentAcronym(_ value: String) -> Bool {
        if CommonNameDetector.names.contains(value.lowercased()) { return false }
        let letters = value.prefix { $0.isLetter }
        guard (2...5).contains(letters.count), letters.allSatisfy(\.isUppercase) else { return false }
        let suffix = value.dropFirst(letters.count)
        if suffix.isEmpty { return true }
        guard suffix.first == "-" else { return false }
        let digits = suffix.dropFirst()
        return (1...2).contains(digits.count) && digits.allSatisfy(\.isNumber)
    }

    /// True for a short run of digits and nothing else — a year, a score. Two bounds, each paid for:
    /// "has no letters in it" also matches `090-1234-5678`, a phone number no deterministic layer
    /// reaches on a bare CSV line. And any length at all reaches a bare member number — `4471209`
    /// identifies someone where `2026` identifies nobody, so the cut is at four digits.
    static func isShortBareNumber(_ value: String) -> Bool {
        (1...4).contains(value.count) && value.allSatisfy(\.isNumber)
    }

    /// The leading part of a value that can still be a name, when the rest reads as ordinary prose —
    /// `Rogerian therapy` → `Rogerian`, `Beck Depression Inventory-II administered` → everything up
    /// to `administered`. Returns nil when the value does not have that shape and should be left
    /// alone.
    ///
    /// A later word starting lower case is the signal, because the parts of a written name are
    /// capitalised. The exception is the particles that join them, so `Anna van der Berg` is one
    /// name and not a name plus prose. Scripts without letter case never trigger this at all — 田中
    /// 陽子 has no upper-case token, so it is exempt and so is `maria gonzalez`.
    static func leadingNameRun(of value: String) -> String? {
        var sawCapitalised = false
        var cut: String.Index?
        var index = value.startIndex
        var isFirstToken = true
        while index < value.endIndex {
            while index < value.endIndex, value[index].isWhitespace { index = value.index(after: index) }
            guard index < value.endIndex else { break }
            let start = index
            while index < value.endIndex, !value[index].isWhitespace { index = value.index(after: index) }
            let token = value[start..<index]
            guard let first = token.first else { break }
            if first.isUppercase { sawCapitalised = true }
            if !isFirstToken, first.isLowercase, !nameParticles.contains(token.lowercased()) {
                cut = start
                break
            }
            isFirstToken = false
        }
        guard sawCapitalised, let cut else { return nil }
        let head = value[value.startIndex..<cut].trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? nil : head
    }

    /// Words that join the parts of a name and are written lower case.
    private static let nameParticles: Set<String> = [
        "van", "von", "de", "del", "della", "da", "das", "di", "do", "dos", "du", "la", "le",
        "las", "los", "der", "den", "el", "san", "santa", "st", "ste",
        "bin", "ibn", "abu", "ben", "al", "mac", "mc", "ter", "ten", "y", "e",
    ]

    /// Re-anchor an entity onto the first `head.count` characters of its own span. Returns nil when
    /// the span cannot be shortened, which leaves the caller holding the untruncated entity.
    ///
    /// The head has to actually start the span. The model copies its value out of the input, but a
    /// composed-vs-decomposed accent or a substituted apostrophe would make the character count lie
    /// about where the name ends, and re-anchoring on a lie moves the redaction off the name.
    private static func truncating(_ entity: DetectedEntity, to head: String, in text: String) -> DetectedEntity? {
        guard case let .text(range) = entity.locus,
              text[range].hasPrefix(head),
              let end = text.index(range.lowerBound, offsetBy: head.count, limitedBy: range.upperBound),
              end > range.lowerBound else { return nil }
        return DetectedEntity(
            id: entity.id,
            type: entity.type,
            value: head,
            confidence: entity.confidence,
            source: entity.source,
            locus: .text(range.lowerBound..<end),
            tokenLabel: entity.tokenLabel,
            disposition: entity.disposition,
            isEnabled: entity.isEnabled
        )
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
    /// interjections, the field labels that sit next to an identifier, and the words a clinical note
    /// uses for the roles and objects in it. That last group is here because the model reads a
    /// capitalised one as a person — `Sessions began in 2026.` came back with `Sessions` as a NAME.
    ///
    /// Deliberately excludes words that are also common names — both English (will, may, mark,
    /// grace, rose, dawn, hope, faith) and short romanized names (so, an, he, we, no, hi) — so those
    /// still redact. The gazetteer check in `isAllFunctionWords` is a second guard for names that
    /// slip in, and the whole set only ever fires when EVERY word in a value is in it, so
    /// `Patient Sarah Chen` is untouched.
    private static let functionWords: Set<String> = [
        "a", "the", "this", "that", "these", "those", "here", "there", "then",
        "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did", "has", "have", "had",
        "i", "you", "she", "they", "it", "me", "us", "them", "him",
        "my", "your", "our", "their", "his", "her", "its", "mine", "yours", "ours", "theirs",
        "of", "to", "in", "on", "at", "for", "with", "from", "by", "as", "about", "into", "onto", "over",
        "and", "or", "but", "if", "than", "because", "while", "when", "where", "which", "who", "whom",
        "hey", "hello", "yeah", "yep", "okay", "please", "thanks", "thank", "yes", "not",
        "ssn", "dob", "phone", "email", "address", "name",
        "patient", "patients", "client", "clients", "member", "subscriber", "interpreter",
        "provider", "clinician", "counselor", "counsellor", "therapist", "therapy", "session",
        "sessions", "visit", "visits", "encounter", "chart", "history", "treatment", "assessment",
        "referral", "discharge", "admission", "score", "scores",
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
