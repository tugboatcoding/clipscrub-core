import XCTest
@testable import ClipscrubKit

final class EngineAndRedactorTests: XCTestCase {
    // Synthetic clinical snippet — no real PHI.
    static let clinical = """
    Patient John Smith, SSN 123-45-6789, MRN: A1234567, \
    email john.smith@example.com, phone (415) 555-0132.
    """

    func testEngineReturnsDisjointSpans() async throws {
        let entities = try await RedactionPipeline.makeDefault()
            .run(text: Self.clinical).entities
        let spans = entities
            .compactMap { $0.offsets(in: Self.clinical) }
            .map { ($0.start, $0.start + $0.length) }
            .sorted { $0.0 < $1.0 }
        for (a, b) in zip(spans, spans.dropFirst()) {
            XCTAssertLessThanOrEqual(a.1, b.0, "spans \(a) and \(b) overlap")
        }
    }

    func testHigherConfidenceSpanWinsOverlap() {
        let text = "id x"
        func entity(_ type: EntityType, _ conf: Double, _ range: Range<String.Index>, _ src: DetectionSource) -> DetectedEntity {
            DetectedEntity(type: type, value: String(text[range]), confidence: conf, source: src, locus: .text(range))
        }
        let whole = text.startIndex..<text.endIndex
        let inner = text.startIndex..<text.index(text.startIndex, offsetBy: 2)
        let resolved = DetectionEngine.resolveOverlaps(
            [entity(.email, 0.9, whole, .regex), entity(.name, 0.6, inner, .nlTagger)],
            in: text
        )
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.type, .email)
    }

    func testRedactionScrubsSourceValues() async throws {
        let result = try await RedactionPipeline.makeDefault().run(text: Self.clinical)
        for leaked in ["123-45-6789", "john.smith@example.com", "A1234567"] {
            XCTAssertFalse(result.redactedText.contains(leaked), "leaked \(leaked)")
        }
        XCTAssertTrue(result.redactedText.contains("[SSN_1]"))
        XCTAssertTrue(result.redactedText.contains("[EMAIL_1]"))
    }

    func testTokenConsistency() async throws {
        let same = try await RedactionPipeline.makeDefault()
            .run(text: "reach a@b.com or a@b.com").redactedText
        XCTAssertTrue(same.contains("[EMAIL_1]"))
        XCTAssertFalse(same.contains("[EMAIL_2]"))

        let distinct = try await RedactionPipeline.makeDefault()
            .run(text: "reach a@b.com or c@d.com").redactedText
        XCTAssertTrue(distinct.contains("[EMAIL_1]"))
        XCTAssertTrue(distinct.contains("[EMAIL_2]"))
    }

    func testBareDomainNestedInURLDedupsToOneEntity() async throws {
        // acme-clinic.com is a TLD NSDataDetector already recognizes as a link, so the domain
        // regex match nests fully inside the .url span — resolveOverlaps must drop to one entity.
        let engine = DetectionEngine(detectors: [
            DataDetectorDetector(),
            try RegexRulesetDetector(ruleset: Ruleset.bundled()),
        ])
        let text = "visit acme-clinic.com for records"
        let found = try await engine.detect(in: .text(text))
        let matching = found.filter { $0.offsets(in: text)?.length == "acme-clinic.com".count }
        XCTAssertEqual(matching.count, 1, "expected exactly one surviving span over the domain")
    }

    func testDomainOnlyTLDSurfacesWhenDataDetectorMisses() async throws {
        // .mil / .int aren't in NSDataDetector's recognized TLD set, so only the domain rule fires.
        let engine = DetectionEngine(detectors: [
            DataDetectorDetector(),
            try RegexRulesetDetector(ruleset: Ruleset.bundled()),
        ])
        let text = "reach us at intranet.hospital.mil today"
        let found = try await engine.detect(in: .text(text))
        XCTAssertTrue(found.contains { $0.type == .other("domain") && $0.value == "intranet.hospital.mil" })
    }

    func testDisabledEntitiesLeftUntouched() {
        let text = "SSN 123-45-6789"
        let range = try! XCTUnwrap(text.range(of: "123-45-6789"))
        var entity = DetectedEntity(type: .ssn, value: "123-45-6789", confidence: 0.9, source: .regex, locus: .text(range))
        entity.isEnabled = false
        let result = TextRedactor().redact(text, entities: [entity])
        XCTAssertEqual(result.redactedText, text)
    }

    func testEntityReportsOmitRawValue() async throws {
        let result = try await RedactionPipeline.makeDefault().run(text: Self.clinical)
        let json = try JSONEncoder().encode(result.reports(over: Self.clinical))
        let string = String(decoding: json, as: UTF8.self)
        for leaked in ["123-45-6789", "john.smith@example.com", "A1234567"] {
            XCTAssertFalse(string.contains(leaked), "report leaked \(leaked)")
        }
    }
}
