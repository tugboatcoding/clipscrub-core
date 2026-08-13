import Foundation

/// Editable prompt config (bundled `llm-prompt.json`) so the wording + category list can be tuned
/// without a code change. Falls back to a built-in default if the file is missing or malformed, so a
/// bad edit degrades the LLM tier's phrasing but never breaks detection.
///
/// This lives outside `#if canImport(FoundationModels)` because `DetectionEngine` reads `categories`
/// to decide whether a model finding used a category the prompt actually offered. That check has to
/// compile on every toolchain, including the ones where the model tier itself does not exist.
struct LLMPrompt: Codable {
    var instructions: String
    var promptTemplate: String // supports {categories} and {text} placeholders
    var categories: [String]

    static let fallback = LLMPrompt(
        instructions: "You detect PHI and PII in text for redaction. Copy identifier values verbatim from the input. Only flag text that actually identifies a person. Ordinary words and sentence filler are not identifiers. When unsure, leave it out.",
        promptTemplate: "List every PHI/PII identifier in this text. For each give its category (one of: {categories}) and the exact value copied verbatim.\n\n{text}",
        categories: ["NAME", "ADDRESS", "ZIP", "DOB", "DATE", "PHONE", "FAX", "EMAIL", "SSN",
                     "MRN", "ACCOUNT", "LICENSE", "BENEFICIARY", "IP", "URL", "DEVICE", "VEHICLE",
                     "AGE", "SEX", "RACE", "MARITAL", "OTHER"]
    )

    static func load() -> LLMPrompt {
        // Resolved from the Kit resource bundle so any ClipscrubKit consumer, including the
        // `clipscrub` CLI, finds it.
        guard let url = Bundle.module.url(forResource: "llm-prompt", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(LLMPrompt.self, from: data) else {
            return .fallback
        }
        return config
    }

    /// The category labels the prompt offered the model, upper-cased for comparison. Read once —
    /// the gate consults this per finding and the file cannot change mid-run.
    static let offeredCategories: Set<String> = Set(load().categories.map { $0.uppercased() })

    func userPrompt(text: String) -> String {
        promptTemplate
            .replacingOccurrences(of: "{categories}", with: categories.joined(separator: ", "))
            .replacingOccurrences(of: "{text}", with: text)
    }
}
