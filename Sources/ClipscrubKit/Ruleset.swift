import Foundation

public enum ClipscrubError: Error, Sendable {
    case rulesetMissing
    case invalidPattern(rule: String, underlying: String)
}

/// One data-driven regex rule. Patterns live in `Resources/ruleset.json` (US + generic
/// defaults) so the identifier ruleset is editable config, not hardcoded logic.
public struct RegexRule: Codable, Sendable {
    public let type: String
    public let name: String
    public let pattern: String
    public let confidence: Double
    /// Labelled-field rules (e.g. `Age: 47`, `Sex: Female`) must match regardless of case. Optional
    /// so existing rules stay case-sensitive by default. One bad pattern still drops the whole layer,
    /// so keep patterns simple.
    public let caseInsensitive: Bool?

    public init(type: String, name: String, pattern: String, confidence: Double, caseInsensitive: Bool? = nil) {
        self.type = type
        self.name = name
        self.pattern = pattern
        self.confidence = confidence
        self.caseInsensitive = caseInsensitive
    }
}

public struct Ruleset: Codable, Sendable {
    public let version: Int
    public let rules: [RegexRule]

    public init(version: Int, rules: [RegexRule]) {
        self.version = version
        self.rules = rules
    }

    /// The default ruleset bundled with the package.
    public static func bundled() throws -> Ruleset {
        guard let url = Bundle.module.url(forResource: "ruleset", withExtension: "json") else {
            throw ClipscrubError.rulesetMissing
        }
        return try JSONDecoder().decode(Ruleset.self, from: Data(contentsOf: url))
    }
}
