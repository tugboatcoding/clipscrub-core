import XCTest
@testable import ClipscrubKit

final class LabelledIdentifierTests: XCTestCase {
    func testMedicalRecordLabelsCoverCompleteValues() async throws {
        let detector = try RegexRulesetDetector(ruleset: Ruleset.bundled())
        for (label, value) in [
            ("MRN Number: ", "B7654321"),
            ("Medical record number: ", "C9274610"),
            ("MRN:\n  ", "D6382159")
        ] {
            let text = "\(label)\(value)\n\(label)\(value)\nKeep this sentence."
            let found = try await detector.detect(in: .text(text))
            XCTAssertEqual(found.filter { $0.type == .mrn && $0.value.contains(value) }.count, 2, label)
            let result = TextRedactor().redact(text, entities: found).redactedText
            XCTAssertFalse(result.contains(value), label)
            XCTAssertTrue(result.contains("Keep this sentence."))
        }
    }

    func testExpandedMedicalRecordLabelsSupportUnicodeWhitespace() async throws {
        let detector = try RegexRulesetDetector(ruleset: Ruleset.bundled())
        for label in ["Medical record number:", "MRN Number:", "MRN no."] {
            for separator in ["\u{00A0}", "\u{2009}", "\u{202F}"] {
                let value = "M9274610"
                let line = "\(label)\(separator)\(value)"
                let text = "\(line)\n\(line)\nKeep this sentence."
                let found = try await detector.detect(in: .text(text))
                XCTAssertEqual(found.filter { $0.type == .mrn && $0.value.contains(value) }.count, 2, line)
                XCTAssertFalse(TextRedactor().redact(text, entities: found).redactedText.contains(value), line)
            }
        }
    }

    func testLicenceLabelsCoverCompleteValues() async throws {
        let detector = try RegexRulesetDetector(ruleset: Ruleset.bundled())
        for (label, value) in [
            ("Driver's license no.: ", "F9372610"),
            ("DRIVING LICENCE NUMBER: ", "G5263819"),
            ("Driver’s license: ", "H7261938"),
            ("DLN:\n  ", "J8372619")
        ] {
            let text = "\(label)\(value)\n\(label)\(value)\nKeep this sentence."
            let found = try await detector.detect(in: .text(text))
            XCTAssertEqual(found.filter { $0.type == .license && $0.value.contains(value) }.count, 2, label)
            XCTAssertFalse(TextRedactor().redact(text, entities: found).redactedText.contains(value), label)
        }
    }

    func testLegacyLicenceWhitespaceRemainsSupported() async throws {
        let detector = try RegexRulesetDetector(ruleset: Ruleset.bundled())
        let text = "DL:\u{00A0}L1234567"
        let found = try await detector.detect(in: .text(text))
        XCTAssertEqual(found.filter { $0.type == .license }.count, 1)
        XCTAssertFalse(TextRedactor().redact(text, entities: found).redactedText.contains("L1234567"))
    }

    func testExpandedLabelsLeaveProseAndHeadersAlone() async throws {
        let detector = try RegexRulesetDetector(ruleset: Ruleset.bundled())
        for text in ["MRN Number, MRN Column, MRN Values", "Medical record number missing",
                     "Medical record reviewed today", "Driver's license number missing",
                     "Driving licence renewed today", "Build 8127346", "Dose 250 mg twice daily.",
                     "The encounter was brief and uneventful."] {
            let found = try await detector.detect(in: .text(text))
            XCTAssertFalse(found.contains { $0.type == .mrn || $0.type == .license }, text)
        }
    }
}
