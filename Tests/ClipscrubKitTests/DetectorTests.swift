import XCTest
@testable import ClipscrubKit

// All fixtures below are synthetic — no real PHI.

final class DetectorTests: XCTestCase {
    func testRegexRulesetCatchesStructuredIdentifiers() async throws {
        let detector = try RegexRulesetDetector(ruleset: Ruleset.bundled())
        let text = """
        SSN 123-45-6789, email a.user@example.com, host 10.0.12.7,
        MRN: A1234567, token eyJhbGc.eyJzdWI.sIgnAtUrE
        """
        let found = try await detector.detect(in: .text(text))
        let types = Set(found.map(\.type))
        XCTAssertTrue(types.contains(.ssn))
        XCTAssertTrue(types.contains(.email))
        XCTAssertTrue(types.contains(.ipAddress))
        XCTAssertTrue(types.contains(.mrn))
        XCTAssertTrue(types.contains(.other("jwt")))
        XCTAssertTrue(found.contains { $0.type == .ssn && $0.value == "123-45-6789" })
    }

    func testDataDetectorCatchesPhoneNumber() async throws {
        let found = try await DataDetectorDetector().detect(in: .text("Call me at (415) 555-0132 tomorrow."))
        XCTAssertTrue(found.contains { $0.type == .phone })
    }

    func testNLTaggerFlagsPersonalName() async throws {
        let found = try await NameEntityDetector().detect(in: .text("Barack Obama visited the clinic in Chicago."))
        XCTAssertTrue(found.contains { $0.type == .name && $0.value.contains("Obama") })
    }

    func testCommonNameDetectorLoadsBundledListAcrossLocales() async throws {
        // Standalone / ALL-CAPS names the statistical NER misses, spanning several locale buckets in
        // given-names.json — proves the resource loaded and every language key was merged, not just "en".
        let detector = CommonNameDetector()
        for name in ["JANICE", "MARC", "JOSE", "FATIMA"] {
            let found = try await detector.detect(in: .text("chart signed by \(name) today"))
            XCTAssertTrue(found.contains { $0.type == .name && $0.value == name }, "expected \(name) flagged")
        }
        let none = try await detector.detect(in: .text("the appointment was rescheduled"))
        XCTAssertTrue(none.isEmpty, "ordinary words are not flagged as names")
    }

    func testRegexRulesetCatchesMonthYearDates() async throws {
        // NSDataDetector's .date type needs a day component and misses month+year alone
        // (operator QA: "September 2011" passed through unredacted) — covered by the ruleset instead.
        let detector = try RegexRulesetDetector(ruleset: Ruleset.bundled())
        for text in ["September 2011", "Sep 2011", "September, 2011", "SEPTEMBER 2011"] {
            let found = try await detector.detect(in: .text(text))
            XCTAssertTrue(found.contains { $0.type == .date }, "expected date match in '\(text)'")
        }
        for text in ["maybe 2011 was", "2011 September-ish", "may be 2011"] {
            let found = try await detector.detect(in: .text(text))
            XCTAssertFalse(found.contains { $0.type == .date }, "unexpected date match in '\(text)'")
        }
    }

    func testRegexRulesetCatchesBareDomains() async throws {
        let detector = try RegexRulesetDetector(ruleset: Ruleset.bundled())
        for text in ["acme-clinic.com", "intranet.hospital.org", "hospital.mil", "sub.hospital.int", "Acme.Com"] {
            let found = try await detector.detect(in: .text(text))
            XCTAssertTrue(found.contains { $0.type == .other("domain") }, "expected domain match in '\(text)'")
        }
    }

    func testRegexRulesetSkipsNonDomainShapes() async throws {
        let detector = try RegexRulesetDetector(ruleset: Ruleset.bundled())
        for text in ["file.txt", "v1.2.3", "e.g.", "etc.", "1.2.3.4", "closed the bins.So the plan"] {
            let found = try await detector.detect(in: .text(text))
            XCTAssertFalse(found.contains { $0.type == .other("domain") }, "unexpected domain match in '\(text)'")
        }
    }

    func testEmptyInputYieldsNoDetections() async throws {
        let detector = try RegexRulesetDetector(ruleset: Ruleset.bundled())
        let empty = DetectionInput.text("")
        let regexResult = try await detector.detect(in: empty)
        let dataResult = try await DataDetectorDetector().detect(in: empty)
        let nerResult = try await NameEntityDetector().detect(in: empty)
        XCTAssertTrue(regexResult.isEmpty)
        XCTAssertTrue(dataResult.isEmpty)
        XCTAssertTrue(nerResult.isEmpty)
    }
}
