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

    func testNLTaggerFindsNamesInAColumnWithNoSentence() async throws {
        // A calendar or roster column is bare lines, and the name model leans on sentence context:
        // "Dee Okonkwo" on its own tags as nothing while the same name inside a sentence tags fine.
        let column = """
        Mon 2
        Dee Okonkwo
        90837 - 60 min
        open
        Alan Voss Jr.
        Consult - Dr. Hale
        K. Nwosu (intake)
        """
        // Swift reads CRLF as one character, so a Windows document has no "\n" in it at all and a
        // line split that looks for one sees the whole file as a single line.
        for (ending, label) in [("\n", "LF"), ("\r\n", "CRLF")] {
            let text = column.replacingOccurrences(of: "\n", with: ending)
            let found = try await NameEntityDetector().detect(in: .text(text))
            for name in ["Dee Okonkwo", "Alan Voss Jr.", "Dr. Hale", "K. Nwosu"] {
                XCTAssertTrue(found.contains { $0.type == .name && $0.value.contains(name) },
                              "expected \(name) flagged in \(label)")
            }
            // A carrier sentence makes weak evidence look strong — a day label or a field heading
            // tags as a name inside one — so a lone token is never enough on its own.
            XCTAssertFalse(found.contains { $0.value == "Mon" }, "a day label is not a name (\(label))")
        }
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
        // ("September 2011" passed through unredacted) — covered by the ruleset instead.
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

    func testColumnHeaderIdentifiesValuesNoPatternCouldMatch() async throws {
        // Three payers, three formats, nothing in common. The header is the only thing that says
        // what they are, which is exactly the case a regex cannot serve.
        let csv = """
        claim_id,member_id,dob,billed
        CLM-1,MHP-4471-88203-01,1958-04-17,210.00
        CLM-2,W99128837,1991-11-03,165.00
        CLM-3,00229-4471-8,1987-06-22,275.00
        """
        let found = try await DelimitedFieldDetector().detect(in: .text(csv))
        let members = found.filter { $0.type == .beneficiary }.map(\.value)
        XCTAssertEqual(Set(members), ["MHP-4471-88203-01", "W99128837", "00229-4471-8"])
        XCTAssertTrue(found.contains { $0.type == .dateOfBirth && $0.value == "1958-04-17" })
        XCTAssertFalse(found.contains { $0.value.hasPrefix("CLM-") }, "claim_id is not a mapped column")
        XCTAssertTrue(found.allSatisfy { $0.source == .structuredField })
    }

    func testAddressColumnsAreFoundAndTheStateIsLeftAlone() async throws {
        // Safe Harbor B removes subdivisions SMALLER than a state, so the state itself must stay
        // readable. Adding `state` to the column table is a one-line change that reads like a
        // completeness fix and is over-redaction with a rule against it.
        let csv = """
        claim_id,member_name,address,city,state,zip
        CLM-1,Tobias Renner,88 Ashgrove Lane,Erlanger,KY,41018
        CLM-2,Priya Raghavan,12 Cedar Court,Florence,KY,41042
        """
        let found = try await DelimitedFieldDetector().detect(in: .text(csv))
        XCTAssertEqual(
            Set(found.filter { $0.type == .address }.map(\.value)),
            ["88 Ashgrove Lane", "Erlanger", "41018", "12 Cedar Court", "Florence", "41042"],
        )
        XCTAssertEqual(
            Set(found.filter { $0.type == .name }.map(\.value)),
            ["Tobias Renner", "Priya Raghavan"],
        )
        XCTAssertFalse(found.contains { $0.value == "KY" }, "the state is permitted to stay")
    }

    func testEveryFlagColumnHasAShapeToProveItself() throws {
        // Two ways a flag column goes quiet, both silent: its shape regex fails to compile (the
        // dictionary is built with `try?`), or someone adds a flag column whose type has no shape
        // at all. Either way `shapeAllows` returns false forever and the column simply never fires
        // — no error, no log, just a category that stopped working. This is the alarm.
        for (header, column) in DelimitedFieldDetector.columns where column.disposition == .flag {
            guard case let .other(subtype) = column.type else {
                return XCTFail("flag column '\(header)' must use .other(subtype) so it can carry a shape")
            }
            XCTAssertNotNil(
                DelimitedFieldDetector.codeShapes[subtype],
                "flag column '\(header)' has no compiled shape for '\(subtype)' — it will never fire",
            )
        }
    }

    func testFreeTextInACodeColumnIsNotFlaggedAndKept() async throws {
        // The header says these are diagnosis codes. Most `diagnosis` columns hold sentences, and a
        // sentence claimed by a flag column is a sentence LEFT IN the document — with the names
        // inside it never reaching the detector that would have removed them.
        let csv = """
        patient_name,diagnosis,billed
        Margaret Ellison,Generalised anxiety; spouse Priya Raghavan present,165.00
        Tobias Renner,F41.1,210.00
        """
        let found = try await DelimitedFieldDetector().detect(in: .text(csv))
        XCTAssertFalse(
            found.contains { $0.value.contains("Priya Raghavan") },
            "free text in a code column must fall through to the layers that redact",
        )
        // The cell that really is a code still gets flagged, so the guard didn't just disable it.
        XCTAssertTrue(found.contains { $0.type == .other("icd10") && $0.value == "F41.1" && !$0.isEnabled })
    }

    func testColumnDetectorIgnoresProseAndRaggedTables() async throws {
        let detector = DelimitedFieldDetector()
        // Prose with commas, a two-column list, and a table whose rows disagree with its header.
        // The last one matters most: a bad split reads the neighbouring column and marks the wrong
        // value, so it reports nothing rather than something confidently wrong.
        for text in [
            "She lives in Covington, KY, and her member id is on the card, somewhere.",
            "member_id,notes\nMHP-1,fine",
            "claim_id,member_id,dob\nCLM-1,MHP-4471-88203-01\nCLM-2,W99128837,1991-11-03,extra",
        ] {
            let found = try await detector.detect(in: .text(text))
            XCTAssertTrue(found.isEmpty, "expected no column detections in '\(text.prefix(40))…'")
        }
    }

    func testQuotedFieldWithACommaDoesNotShiftTheColumns() async throws {
        // Split naively, "Covington, KY" becomes two fields and every later column moves left —
        // so the detector would mark the date as a member ID and leave the real one in the clear.
        let csv = """
        claim_id,city,member_id,dob
        CLM-1,"Covington, KY",MHP-4471-88203-01,1958-04-17
        """
        let found = try await DelimitedFieldDetector().detect(in: .text(csv))
        XCTAssertEqual(found.filter { $0.type == .beneficiary }.map(\.value), ["MHP-4471-88203-01"])
        XCTAssertEqual(found.filter { $0.type == .dateOfBirth }.map(\.value), ["1958-04-17"])
    }

    func testLabelledMemberIdIsFoundInProseAndJson() async throws {
        let detector = try RegexRulesetDetector(ruleset: Ruleset.bundled())
        for text in ["Meridian Health Plan, member MHP-4471-88203-01.",
                     "\"memberId\": \"MHP-4471-88203-01\"",
                     "Subscriber ID: W99128837",
                     "Policy no. 00229-4471-8"] {
            let found = try await detector.detect(in: .text(text))
            XCTAssertTrue(found.contains { $0.type == .beneficiary }, "expected a member ID in '\(text)'")
        }
    }

    func testClinicalCodesAreFoundAndFlaggedRatherThanRedacted() async throws {
        let detector = try RegexRulesetDetector(ruleset: Ruleset.bundled())
        for text in ["CPT 90837", "cpt: 90834", "\"cpt\": \"90837\"", "Procedure code 99213", "Dx F41.1", "F33.1", "icd-10 G47"] {
            let found = try await detector.detect(in: .text(text))
            let codes = found.filter { $0.type == .other("cpt") || $0.type == .other("icd10") }
            XCTAssertFalse(codes.isEmpty, "expected a clinical code in '\(text)'")
            for code in codes {
                XCTAssertEqual(code.disposition, .flag, "'\(text)' must be flagged, not redacted")
                // The engine reads isEnabled, so a flag rule that left this on would redact anyway.
                XCTAssertFalse(code.isEnabled, "'\(text)' must start switched off")
            }
        }
    }

    func testClinicalCodeRulesSkipShapesThatMerelyLookLikeCodes() async throws {
        let detector = try RegexRulesetDetector(ruleset: Ruleset.bundled())
        // CO-151 is a denial reason, 41011 a ZIP, 7.4.2 a build. Removing any of them destroys a
        // document to no benefit, and marking them spends the false-positive budget.
        for text in ["Denial CO-151", "Covington KY 41011", "build 7.4.2", "call 90837"] {
            let found = try await detector.detect(in: .text(text))
            XCTAssertFalse(
                found.contains { $0.type == .other("cpt") || $0.type == .other("icd10") },
                "unexpected clinical-code match in '\(text)'"
            )
        }
    }

    func testFlaggedCodeSurvivesRedactionAndIsReportedSeparately() async throws {
        let engine = DetectionEngine(detectors: [
            DataDetectorDetector(),
            try RegexRulesetDetector(ruleset: Ruleset.bundled()),
        ])
        let text = "SSN 402-11-8853, CPT 90837."
        let entities = try await engine.detect(in: .text(text))
        let result = TextRedactor().redact(text, entities: entities)

        XCTAssertTrue(result.redactedText.contains("90837"), "the code must still be in the output")
        XCTAssertFalse(result.redactedText.contains("402-11-8853"), "the SSN must not be")
        XCTAssertTrue(result.flagged.contains { $0.type == .other("cpt") },
                      "a caller that only sees what was removed cannot say what was kept")
        XCTAssertFalse(result.entities.contains { $0.type == .other("cpt") })
    }

    func testTickingAFlaggedCodeRedactsIt() async throws {
        // The one-click escape. disposition stays .flag as a record of what the rule asked for;
        // isEnabled is what redaction reads, so a reader who wants the code gone gets it gone.
        let detector = try RegexRulesetDetector(ruleset: Ruleset.bundled())
        let text = "CPT 90837 was denied."
        var entities = try await detector.detect(in: .text(text))
        for index in entities.indices { entities[index].isEnabled = true }
        let result = TextRedactor().redact(text, entities: entities)

        XCTAssertFalse(result.redactedText.contains("90837"))
        XCTAssertTrue(result.flagged.isEmpty)
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
