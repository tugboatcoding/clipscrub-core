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

    func testPartialOverlapKeepsThePartTheWinnerDoesNotCover() {
        // NLTagger runs the name span one word into the date. The date wins the part they share,
        // and the name must survive on the rest — dropping it whole shipped the name in the clear.
        let text = "Sarah Chen  Jul 1, 2026"
        let resolved = DetectionEngine.resolveOverlaps(
            [entity(.name, 0.6, 0, 15, in: text), entity(.date, 0.85, 12, 11, in: text)], in: text
        )
        XCTAssertEqual(resolved.map(\.value), ["Sarah Chen", "Jul 1, 2026"])
        assertDisjointAndFaithful(resolved, in: text)
    }

    func testThreeStaggeredSpansStayDisjoint() {
        // A third layer overlapping the leftover of the second used to leave the spans out of order.
        let text = "Sarah Chen Jul 1, 2026 at 9:14 AM"
        let resolved = DetectionEngine.resolveOverlaps([
            entity(.name, 0.80, 0, 14, in: text),
            entity(.other("weak"), 0.50, 11, 19, in: text),
            entity(.date, 0.95, 12, 10, in: text),
        ], in: text)
        XCTAssertEqual(resolved.count, 3)
        assertDisjointAndFaithful(resolved, in: text)
    }

    func testWhitespaceOnlyLeftoverIsNotKeptAsASpan() {
        let text = "Jul  Sarah Chen"
        let resolved = DetectionEngine.resolveOverlaps(
            [entity(.name, 0.5, 3, 7, in: text), entity(.date, 0.9, 5, 10, in: text)], in: text
        )
        XCTAssertEqual(resolved.count, 1)
        assertDisjointAndFaithful(resolved, in: text)
    }

    private func entity(_ type: EntityType, _ confidence: Double, _ start: Int, _ length: Int,
                        in text: String) -> DetectedEntity {
        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(lower, offsetBy: length)
        return DetectedEntity(type: type, value: String(text[lower..<upper]), confidence: confidence,
                              source: .regex, locus: .text(lower..<upper))
    }

    /// Spans must come out ascending and disjoint, and each value must still be the text it points at.
    private func assertDisjointAndFaithful(_ entities: [DetectedEntity], in text: String) {
        let spans = entities.compactMap { $0.offsets(in: text) }
        XCTAssertEqual(spans.count, entities.count)
        for (earlier, later) in zip(spans, spans.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.start + earlier.length, later.start, "spans overlap")
        }
        for entity in entities {
            guard case let .text(range) = entity.locus else { return XCTFail("expected a text locus") }
            XCTAssertEqual(String(text[range]), entity.value)
            XCTAssertFalse(entity.value.trimmingCharacters(in: .whitespaces).isEmpty)
        }
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

    /// Every layer down reads exactly like a clean page — an empty result — so the engine has to say
    /// which one it was. Without this the text pipeline hands back the input as redacted output.
    func testEveryDetectorFailingThrowsRatherThanReportingNothingFound() async {
        let engine = DetectionEngine(detectors: [AlwaysThrowingDetector(), AlwaysThrowingDetector()])
        do {
            _ = try await engine.detect(in: .text("SSN 123-45-6789"))
            XCTFail("a total detector outage reported success")
        } catch is DetectionEngineError {
        } catch {
            XCTFail("expected DetectionEngineError, got \(error)")
        }
    }

    /// The floor still holds: one surviving deterministic layer is a result, not an outage.
    func testOneSurvivingDetectorStillReturnsItsFindings() async throws {
        let engine = DetectionEngine(detectors: [
            AlwaysThrowingDetector(),
            try RegexRulesetDetector(ruleset: Ruleset.bundled()),
        ])
        let found = try await engine.detect(in: .text("SSN 123-45-6789"))
        XCTAssertTrue(found.contains { $0.type == .ssn })
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

/// Stand-in for a layer that throws mid-run, e.g. the Foundation Models pass on a long input.
private struct AlwaysThrowingDetector: EntityDetector {
    let source: DetectionSource = .foundationModel
    struct Boom: Error {}
    func detect(in input: DetectionInput) async throws -> [DetectedEntity] { throw Boom() }
}
