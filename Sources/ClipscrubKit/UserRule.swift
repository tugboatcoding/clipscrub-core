import Foundation

/// One pattern the user wrote, for an identifier shape the bundled ruleset does not know about —
/// a customer code, a ticket number, a study id.
///
/// User rules are deliberately NOT stored as `RegexRule`. The bundled ruleset compiles in one go
/// and the first bad pattern throws out of `RegexRulesetDetector.init`, which would take every
/// shipped rule down with it — no SSN detection, no MRN detection, nothing. A user rule has to be
/// able to fail on its own, so it gets its own type and its own detector. See `UserRuleDetector`.
///
/// The other reason for a separate type is what it does NOT carry. `RegexRule` has `confidence`
/// and `disposition` fields, and neither is safe to hand a user. See `confidence` and the note on
/// `UserRuleDetector` for what goes wrong.
public struct UserRule: Codable, Sendable, Identifiable, Equatable {
    /// Identity for the editing UI. Detection never reads it.
    public let id: UUID

    /// What the user calls this rule. Shown in the rules list, and in the error when the pattern
    /// does not compile. It never reaches redacted output — every hit is tokenised `[CUSTOM_n]`,
    /// so a rule someone named after a patient cannot leak that name through the token.
    public var name: String

    /// An ICU regular expression, the same dialect `NSRegularExpression` takes.
    public var pattern: String

    /// Off parks a rule without deleting it. A disabled rule is never compiled, so a pattern that
    /// turned out to be too slow can be switched off instead of retyped.
    public var isEnabled: Bool

    public var caseInsensitive: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        pattern: String,
        isEnabled: Bool = true,
        caseInsensitive: Bool = false
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.isEnabled = isEnabled
        self.caseInsensitive = caseInsensitive
    }
}

public extension UserRule {
    /// Every user rule reports the same subtype, so every hit tokenises as `[CUSTOM_1]`.
    ///
    /// A per-rule subtype would let user-provided text change the result's classification. One fixed
    /// subtype keeps every user-rule hit enabled and makes its output predictable.
    ///
    /// It also keeps user text out of `--report`, which keys its counts on the type identifier.
    /// The report says `custom: 3` and never a string the user wrote.
    static let subtype = "custom"

    static var entityType: EntityType { .other(subtype) }

    /// Fixed, and not exposed. The bundled rules sit between 0.6 and 0.95. At 0.8 a user rule wins
    /// against a name guessed by the NER layer (0.6) and loses to SSN (0.92), email (0.9) and JWT
    /// (0.95), so no pattern a user writes can outrank every shipped rule when two of them overlap.
    static let confidence = 0.8
}

/// Why a user rule could not be used. Both cases name the rule, because the user has to be able to
/// find it in the list — a message about "a pattern" is not actionable when there are twelve.
public enum UserRuleError: Error, Sendable, Equatable {
    /// The pattern is not a valid regular expression. `underlying` is `NSRegularExpression`'s own
    /// message, kept verbatim because it names the offending construct and a rewritten one would not.
    case invalidPattern(rule: String, underlying: String)

    /// The pattern was still running when its time ran out. Almost always catastrophic backtracking
    /// — see `UserRuleDetector.matchBudget`.
    case timedOut(rule: String)
}

// Both conformances, deliberately. The CLI's top-level handler interpolates the error (`"\(error)"`),
// which reads CustomStringConvertible, while AppKit surfaces read localizedDescription, which reads
// LocalizedError. Conform to one and the other surface prints the raw case syntax.
extension UserRuleError: CustomStringConvertible {
    public var description: String { errorDescription ?? "Custom rule failed" }
}

extension UserRuleError: LocalizedError {
    /// Written out because this string is what the person reads. The default for an enum is its own
    /// case syntax, and `timedOut(rule: "Runaway")` on a terminal tells someone their redaction
    /// failed without telling them what to do about it.
    public var errorDescription: String? {
        switch self {
        case .invalidPattern(let rule, let underlying):
            "Custom rule '\(rule)' is not a valid pattern — \(underlying)"
        case .timedOut(let rule):
            // Says nothing was written, because that is the part that matters: the alternative to
            // this error was output that looked redacted and was not.
            "Custom rule '\(rule)' took too long to run, so nothing was redacted. Simplify the pattern or switch it off."
        }
    }
}
