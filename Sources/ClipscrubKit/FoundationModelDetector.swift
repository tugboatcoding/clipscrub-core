// Compiled only where the FoundationModels framework exists (macOS 26 SDK). Excluded on
// older SDKs, so this tier never raises the package floor (macOS 15). Generable conformances
// are written by hand because the @Generable / @Guide macro plugin ships with full Xcode but
// not the Command Line Tools, whose SDK still passes canImport — macros break `swift build`.
#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Structured output for the semantic pass. Guided generation guarantees valid shape;
/// we never parse prose.
@available(macOS 26, *)
struct PHIFindings: Generable {
    var entities: [PHIFinding]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, properties: [
            GenerationSchema.Property(
                name: "entities",
                description: "Every PHI or PII identifier found in the text",
                type: [PHIFinding].self
            ),
        ])
    }

    init(_ content: GeneratedContent) throws {
        entities = try content.value([PHIFinding].self, forProperty: "entities")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["entities": entities])
    }
}

@available(macOS 26, *)
struct PHIFinding: Generable {
    // The authoritative category list lives in the runtime prompt (llm-prompt.json), not the schema —
    // the property description needs a compile-time literal. A stray category is harmless: the value
    // is source-verified and unknown types map to `.other`, still redacted.
    var type: String
    var value: String
    var confidence: Double

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, properties: [
            GenerationSchema.Property(
                name: "type",
                description: "An uppercase PHI/PII category label (e.g. NAME, SSN, ADDRESS, DOB). Use OTHER only for a value that truly identifies a person but fits no named category, never for ordinary words",
                type: String.self
            ),
            GenerationSchema.Property(
                name: "value",
                description: "The exact identifier substring, copied verbatim from the input text",
                type: String.self
            ),
            GenerationSchema.Property(
                name: "confidence",
                description: "Confidence from 0.0 to 1.0",
                type: Double.self
            ),
        ])
    }

    init(_ content: GeneratedContent) throws {
        type = try content.value(String.self, forProperty: "type")
        value = try content.value(String.self, forProperty: "value")
        confidence = try content.value(Double.self, forProperty: "confidence")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: [
            "type": type,
            "value": value,
            "confidence": confidence,
        ])
    }
}

// `LLMPrompt` used to live here. It moved to LLMPromptConfig.swift so `DetectionEngine` can read the
// category list on toolchains where this file does not compile.

/// Layer 4: on-device Foundation Models semantic pass. Catches contextual PHI the deterministic
/// layers miss (e.g. a bare name next to a DOB and a diagnosis). Only runs when the model is
/// available — layers 1–3 always run regardless, so redaction is never gated on the LLM.
@available(macOS 26, *)
public struct FoundationModelDetector: EntityDetector {
    public init() {}

    public let source: DetectionSource = .foundationModel

    /// Whether the on-device model is ready (Apple Intelligence enabled + model downloaded).
    public static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// A user-actionable nudge when the smarter LLM tier is off — or nil when it's available OR the
    /// device simply can't run it (never nag about hardware the user can't change). Read live: the
    /// user may enable Apple Intelligence while the app is open.
    public static var offNotice: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is off. Turn it on in System Settings to add smarter, context-aware detection — core redaction already works without it."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is downloading its model. Smarter detection turns on automatically once it's ready."
        case .unavailable(.deviceNotEligible):
            return nil // this Mac can't run the model — nothing to prompt
        @unknown default:
            return nil
        }
    }

    public func detect(in input: DetectionInput) async throws -> [DetectedEntity] {
        guard case let .text(text) = input, !text.isEmpty, Self.isAvailable else { return [] }

        let config = LLMPrompt.load()
        let session = LanguageModelSession { config.instructions }
        let prompt = config.userPrompt(text: text)
        let response = try await session.respond(to: prompt, generating: PHIFindings.self)

        var results: [DetectedEntity] = []
        var consumed: [Range<String.Index>] = []
        for finding in response.content.entities {
            // Source-verify: the model can hallucinate, and may report the same value twice. Only
            // redact values that actually occur in the input, anchoring each to the NEXT
            // un-consumed occurrence so duplicates map to distinct spans (not all to the first).
            guard let range = nextOccurrence(of: finding.value, in: text, skipping: consumed) else { continue }
            consumed.append(range)
            results.append(
                DetectedEntity(
                    type: EntityType(identifier: finding.type),
                    value: finding.value,
                    confidence: min(max(finding.confidence, 0), 1),
                    source: .foundationModel,
                    locus: .text(range)
                )
            )
        }
        return results
    }

    private func nextOccurrence(
        of value: String, in text: String, skipping consumed: [Range<String.Index>]
    ) -> Range<String.Index>? {
        guard !value.isEmpty else { return nil }
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: value, range: searchRange) {
            if !consumed.contains(where: { $0.overlaps(found) }) { return found }
            guard found.upperBound < text.endIndex else { return nil }
            searchRange = found.upperBound..<text.endIndex
        }
        return nil
    }
}
#endif
