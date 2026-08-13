import XCTest
@testable import ClipscrubKit

// The `clipscrub` CLI runs the Foundation Models tier by DEFAULT when available; `--no-llm`
// (makeDefault) forces deterministic-only. Two guarantees hold on any host and are asserted here:
// `--no-llm` output is reproducible, and when the model is unavailable (an SDK without
// FoundationModels, macOS < 26, or Apple Intelligence off) makeWithModel is byte-identical to
// makeDefault. The tier
// is additive — a detector can only ADD spans and overlap resolution never un-redacts, so the
// deterministic floor is structurally preserved. The contextual catch itself (a DOB the rules read
// as a bare DATE) is verified by hand: on-device LLM output is non-deterministic, so it is not a
// gate assertion.
final class FoundationModelTierTests: XCTestCase {
    static let contextual = "Patient Jane Doe, DOB 03/11/1980, dx: melanoma."

    private var modelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return FoundationModelDetector.isAvailable }
        #endif
        return false
    }

    func testNoLLMReproducibleAndScrubsFloor() async throws {
        let first = try await RedactionPipeline.makeDefault().run(text: Self.contextual).redactedText
        let second = try await RedactionPipeline.makeDefault().run(text: Self.contextual).redactedText
        XCTAssertEqual(first, second, "--no-llm output must be reproducible")
        XCTAssertFalse(first.contains("Jane"), "deterministic floor still redacts the name")
        XCTAssertFalse(first.contains("03/11/1980"), "deterministic floor still redacts the date")
    }

    func testWithModelIsNoOpWhenModelUnavailable() async throws {
        try XCTSkipIf(modelAvailable,
                      "model available on this host — tier is additive; contextual catch verified by hand")
        let deflt = try await RedactionPipeline.makeDefault().run(text: Self.contextual).redactedText
        let withModel = try await RedactionPipeline.makeWithModel().run(text: Self.contextual).redactedText
        XCTAssertEqual(withModel, deflt, "no model → makeWithModel must be a no-op vs makeDefault")
    }
}
