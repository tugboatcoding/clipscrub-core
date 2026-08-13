import Foundation

/// Rules a run had to abandon, so something can say so afterwards.
///
/// `DetectionEngine.detect` isolates each layer by catching whatever it throws and moving on, and
/// it keeps no record of which layer that was. That isolation is right — it is what stops one bad
/// layer zeroing out the redaction floor — but it means a user rule that fails at detection time
/// leaves no trace at all. The user would see a rule switched on in the list, quietly matching
/// nothing. This is the channel that stops that being silent. Read it after a run and surface what
/// it holds.
public actor UserRuleDiagnostics {
    private var timedOut: Set<String> = []

    public init() {}

    func recordTimeout(rule: String) {
        timedOut.insert(rule)
    }

    /// Rules abandoned since the last `drain`, sorted so the UI order is stable.
    ///
    /// Reading does not reset. An engine outlives many passes, so a caller that reads this without
    /// draining is reporting the worst thing that ever happened rather than what just happened —
    /// the pipelines drain instead, which is why they can fail a single pass accurately.
    public var timedOutRules: [String] {
        timedOut.sorted()
    }

    /// Take the abandoned rules and reset in one step.
    ///
    /// Read-then-clear as two calls leaves a window where a rule that times out between them is
    /// forgotten, and a forgotten timeout is output that ships as redacted with a pattern still in
    /// it. Pipelines drain at the start of a pass to discard anything stale and again at the end to
    /// find out what this pass lost.
    public func drain() -> [String] {
        let names = timedOut.sorted()
        timedOut.removeAll()
        return names
    }
}

/// The user's own patterns, run as their own layer after the bundled ones.
///
/// Separate from `RegexRulesetDetector` on purpose, and the two must not be merged. That detector
/// compiles the whole bundled ruleset in its initialiser and throws on the first bad pattern, which
/// is correct for content we ship and reviewed. Applied to user input it would mean one typo in one
/// custom pattern throws out of `RedactionPipeline.makeDefault()` and the caller gets no pipeline at
/// all — no SSN, no MRN, no email detection, nothing. So this one never throws while being built.
public struct UserRuleDetector: EntityDetector {
    public let source: DetectionSource = .userRule

    /// How long one pattern gets over one input before it is abandoned.
    ///
    /// `NSRegularExpression` takes no timeout, and a pattern like `(a+)+$` backtracks for longer
    /// than anyone will wait once the input is a page of OCR'd text. Without a bound the caller hangs
    /// and the user reads that as a crash. 250ms is far more than a sane pattern needs over a page
    /// and far less than a person will sit through.
    public static let matchBudget: Duration = .milliseconds(250)

    /// A rule that could not be compiled, and the reason in the words of the regex engine.
    public struct Rejected: Sendable, Equatable {
        public let id: UUID
        public let name: String
        public let reason: String
    }

    private struct Compiled {
        let name: String
        let regex: NSRegularExpression
    }

    private let compiled: [Compiled]

    /// Rules that did not compile. Never empty silently — show these next to the rules that did.
    public let rejected: [Rejected]

    /// True when nothing compiled, so callers can skip appending a layer with no work to do.
    public var isEmpty: Bool { compiled.isEmpty }

    private let diagnostics: UserRuleDiagnostics?

    /// Compiles each rule on its own and keeps the ones that work.
    ///
    /// Never throws. A single `try?` around the whole set would be the opposite mistake — one bad
    /// pattern would drop every good one with it, and the user would watch eleven working rules stop
    /// working because of a typo in the twelfth.
    public init(rules: [UserRule], diagnostics: UserRuleDiagnostics? = nil) {
        var compiled: [Compiled] = []
        var rejected: [Rejected] = []
        for rule in rules where rule.isEnabled {
            let options: NSRegularExpression.Options = rule.caseInsensitive ? [.caseInsensitive] : []
            do {
                compiled.append(
                    Compiled(name: rule.name, regex: try NSRegularExpression(pattern: rule.pattern, options: options))
                )
            } catch {
                rejected.append(Rejected(id: rule.id, name: rule.name, reason: error.localizedDescription))
            }
        }
        self.compiled = compiled
        self.rejected = rejected
        self.diagnostics = diagnostics
    }

    public func detect(in input: DetectionInput) async throws -> [DetectedEntity] {
        guard case let .text(text) = input, !text.isEmpty else { return [] }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var results: [DetectedEntity] = []

        for rule in compiled {
            try Task.checkCancellation()

            var found: [DetectedEntity] = []
            var expired = false
            let deadline = ContinuousClock.now.advanced(by: Self.matchBudget)

            // `.reportProgress` is what makes the budget reachable. Without it the block is only
            // called on a match, so a pattern that backtracks without ever matching never yields and
            // there is no moment to stop it in.
            rule.regex.enumerateMatches(in: text, options: [.reportProgress], range: fullRange) { match, _, stop in
                if ContinuousClock.now >= deadline {
                    expired = true
                    stop.pointee = true
                    return
                }
                guard let match, let range = Range(match.range, in: text) else { return }
                found.append(
                    DetectedEntity(
                        type: UserRule.entityType,
                        value: String(text[range]),
                        confidence: UserRule.confidence,
                        source: .userRule,
                        locus: .text(range)
                    )
                )
            }

            // An abandoned rule read part of the input, so what it found is a partial answer. Keeping
            // it would redact the first three customer codes on the page and leave the fourth in the
            // clear, which reads as a finished job. Drop the lot and say the rule was abandoned.
            // Only this rule is dropped — the others already ran and their answers are complete.
            if expired {
                await diagnostics?.recordTimeout(rule: rule.name)
                continue
            }
            results += found
        }

        return results
    }
}
