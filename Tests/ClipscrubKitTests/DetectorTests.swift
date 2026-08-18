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

    func testMrnAndAccountLabelsMatchRegardlessOfCase() async throws {
        // Only the LABEL ("mrn"/"acct") matches case-insensitively — the mrn value class stays
        // uppercase-only. A bare top-level caseInsensitive flag also lower-cased [A-Z0-9], so
        // "MRN Number"/"MRN Column" started matching as if they were record numbers; scoping the
        // flag to `(?i:MRN)` in the pattern instead keeps that closed. This is the test that would
        // have caught both the original miss (lowercase label) and that regression (widened value
        // class), and it also catches a typo'd JSON key silently reverting the fix.
        let detector = try RegexRulesetDetector(ruleset: Ruleset.bundled())
        for text in ["mrn: A1234567, acct: 12345678", "MRN: A1234567, ACCT: 12345678"] {
            let found = try await detector.detect(in: .text(text))
            XCTAssertTrue(found.contains { $0.type == .mrn }, "expected mrn match in '\(text)'")
            XCTAssertTrue(found.contains { $0.type == .account }, "expected account match in '\(text)'")
        }
        let headerNoise = try await detector.detect(in: .text("MRN Number, MRN Column, MRN Values"))
        XCTAssertFalse(headerNoise.contains { $0.type == .mrn }, "a table header is not a record number")
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

    func testConditionAndInstrumentNamesAreNotPeople() async throws {
        // Measured: `Patient has Parkinson's disease.` came back as `Patient has [ORG_1]'s disease.`
        // Taking the condition out of a note destroys the reason the note was shared, which is the
        // same harm as blacking out a diagnosis code.
        for text in [
            "Patient has Parkinson's disease.",
            "Beck Depression Inventory-II administered.",
            "Romberg's reflex was negative.",
        ] {
            let found = try await NameEntityDetector().detect(in: .text(text))
            XCTAssertTrue(found.isEmpty, "flagged a condition or instrument as a person in: \(text) — \(found.map(\.value))")
        }
    }

    func testTheConditionFramesNeverSwallowARealName() async throws {
        // The half of this that cannot be got wrong. Each of these puts a real name inside or in
        // front of a frame, and each is a surname shipped in the clear if the rule wins. The first
        // three reach one guard each and nothing else, so removing any single guard fails this test.
        for (text, name) in [
            ("Tobias Renner Battery ordered.", "Renner"),             // more than one word
            ("Mx. Renner's disease has progressed.", "Renner"),       // a title before it
            ("Sarah Battery ordered.", "Sarah"),                      // a known name inside the frame
            // A whole name tagged as one span reaches the end of the frame. There is no way to tell
            // `Renner Voss Questionnaire` from `Hamilton Anxiety Questionnaire`, so both are kept.
            ("Renner Voss Questionnaire ordered.", "Renner"),
            // A hyphen joins words the same way a space does. Testing only for whitespace reads this
            // as one word and drops it.
            ("Lloyd-Jones Battery ordered.", "Lloyd-Jones"),
            // An apostrophe has to separate words for the gazetteer guard to see `alice` at all.
            ("Alice's disease is stable.", "Alice"),
            ("Alice\u{2019}s disease is stable.", "Alice"),
            ("Alice Parkinson's disease is stable.", "Parkinson"),
            ("Mr. Parkinson's disease has progressed.", "Parkinson"),
            ("Sarah Chen Battery ordered.", "Chen"),
            ("Ms. Beck's test was negative.", "Beck"),                // `test` is not a frame word
            ("Dr. Parkinson reviewed the chart.", "Parkinson"),
            // Words that are eponym words in a textbook and ordinary words in a note.
            ("Nwosu's law firm called.", "Nwosu"),
            ("Okonkwo's area of residence was updated.", "Okonkwo"),
            ("Ferguson Discharge Schedule attached.", "Ferguson"),
            // One word in front of the head noun is a person holding a piece of equipment, not an
            // instrument. An instrument named after someone carries what it measures too.
            ("Wilson Battery ordered for follow-up.", "Wilson"),
            // A title with no space after the stop. A tight layout writes it this way and so does an
            // OCR read of one.
            ("Seen by Mr.Renner's disease notes.", "Renner"),
        ] {
            let found = try await NameEntityDetector().detect(in: .text(text))
            XCTAssertTrue(found.contains { $0.value.contains(name) },
                          "lost \(name) in: \(text) — \(found.map(\.value))")
        }
    }

    func testOneNameBeforeInstrumentHeadIsKept() throws {
        // This boundary must be tested without NLTagger. macOS 14 does not tag `Renner` in this
        // short sentence, but the filter must still preserve a name supplied by any detector.
        let text = "Renner Inventory filed."
        let range = try XCTUnwrap(text.range(of: "Renner"))
        let name = DetectedEntity(type: .name, value: "Renner", confidence: 0.8,
                                  source: .nlTagger, locus: .text(range))

        let kept = NameEntityDetector.dropNamesThatAreNotNames([name], in: text)

        XCTAssertTrue(kept.contains { $0.value == "Renner" })
    }

    func testAFrameNeverReachesAcrossALineBreak() async throws {
        // OCR wraps a line wherever the page did, so a frame that spans the break joins two
        // sentences that were never next to each other — and a title on the line above stops
        // guarding the name below it.
        for ending in ["\n", "\r\n"] {
            let text = "Seen by Dr.\(ending)Renner's disease notes were filed."
            let found = try await NameEntityDetector().detect(in: .text(text))
            XCTAssertTrue(found.contains { $0.value.contains("Renner") }, "lost Renner across \(ending.debugDescription)")
        }
    }

    func testTheFramePatternsCompile() {
        // A pattern that fails to compile silently switches the whole rule off, which reads as the
        // engine simply over-redacting again rather than as a broken build.
        XCTAssertNotNil(NameEntityDetector.eponymPattern)
        XCTAssertNotNil(NameEntityDetector.instrumentPattern)
        XCTAssertNotNil(NameEntityDetector.titlePattern)
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

    func testJsonKeysAreReadTheSameWayAsCsvHeaders() async throws {
        // Eight digits under an `mrn` key have no shape a pattern can match and no literal "MRN"
        // beside them to anchor on, so the regex layers cannot see them. The key is the only
        // signal, which is the same reason the CSV detector reads its header.
        let json = """
        {"mrn": "88214309", "patient_id": "44712", "member_id": "MHP-4471-88203-01",
         "state": "KY", "id": "row-7", "visit_note": "seen in clinic"}
        """
        let found = try await JSONFieldDetector().detect(in: .text(json))
        XCTAssertEqual(Set(found.filter { $0.type == .mrn }.map(\.value)), ["88214309", "44712"])
        XCTAssertEqual(found.filter { $0.type == .beneficiary }.map(\.value), ["MHP-4471-88203-01"])
        // Safe Harbor B keeps the state, and a bare `id` is as likely a row number as a person —
        // both deliberately absent from the shared column table, both must stay readable.
        XCTAssertFalse(found.contains { $0.value == "KY" || $0.value == "row-7" })
        XCTAssertTrue(found.allSatisfy { $0.source == .structuredField })
    }

    func testAnUnquotedKeyColonLineIsNotReadAsAField() async throws {
        // Why this detector is JSON-only. `Street:` and `city:` are mapped column names and these
        // lines are sentences — the CSV sibling tells them apart with "several columns, rows that
        // agree", and there is no equivalent signal on a lone line. A QUOTED key is the signal, so
        // these unquoted ones are left to the other layers.
        //
        // The name says unquoted, not prose, because a quoted key inside a sentence goes the other
        // way. The test below covers that case.
        let detector = JSONFieldDetector()
        for prose in ["Street: where I grew up",
                      "city: the one with the bridge",
                      "Note: the patient improved.",
                      "mrn: 88214309"] {
            let found = try await detector.detect(in: .text(prose))
            XCTAssertTrue(found.isEmpty, "an unquoted line was read as a field: '\(prose)'")
        }
    }

    func testAQuotedKeyInsideASentenceIsStillTreatedAsAField() async throws {
        // The cost of using a quoted key as the signal: documentation or a chat log that QUOTES a
        // JSON fragment gets that fragment redacted.
        //
        // That is the intended behaviour. It over-redacts, which is the direction
        // DelimitedFieldDetector chose for the same reason — a redact column guessing wrong costs
        // the reader a word, while the alternative here is worse. Requiring surrounding braces
        // would drop a snippet pasted without them, trading a harmless extra redaction for a miss.
        let found = try await JSONFieldDetector().detect(
            in: .text(#"The export uses "city": "Covington" for the town field."#)
        )
        XCTAssertEqual(found.map(\.value), ["Covington"])
    }

    func testAnArrayValueIsReadElementByElement() async throws {
        // `"mrn": ["88214309"]` is an ordinary export shape, and a pattern that only accepts a
        // scalar reads it as no value at all. An array holding OBJECTS is skipped whole instead:
        // sweeping it would hand a nested member's value to the outer key, and the key pass
        // already matches those members on their own.
        let flat = try await JSONFieldDetector().detect(in: .text(#"{"mrn": ["88214309", "71120044"]}"#))
        XCTAssertEqual(flat.filter { $0.type == .mrn }.map(\.value), ["88214309", "71120044"])

        let nested = try await JSONFieldDetector().detect(in: .text(#"{"mrn": [{"foo": "bar"}]}"#))
        XCTAssertTrue(nested.isEmpty, "an array of objects was swept as if its members were mrn values")
    }

    func testTheKeyBeatsAShapeGuessAboutTheValue() async throws {
        // End to end, because this is settled by DetectionEngine overlap resolution and not by the
        // detector: `88-2143-09` looks enough like a phone number that the data detector claims it,
        // and a medical record number labelled PHONE is a wrong answer that still ships redacted.
        // The keyed field is 0.9 against its 0.85, so the key wins.
        let engine = DetectionEngine(detectors: [
            DataDetectorDetector(),
            try RegexRulesetDetector(ruleset: Ruleset.bundled()),
            JSONFieldDetector(),
        ])
        let found = try await engine.detect(in: .text("{\"mrn\": \"88-2143-09\"}"))
        XCTAssertEqual(found.filter { $0.value == "88-2143-09" }.map(\.type), [.mrn])
    }

    func testAnEscapedQuoteDoesNotEndTheValueEarly() async throws {
        // A value ending at the first `\"` would leave the rest of it in the clear, which is the
        // failure that matters here — the tail of an identifier is still an identifier.
        let json = #"{"patient_name": "O\"Brien, Margaret", "mrn": "88214309"}"#
        let found = try await JSONFieldDetector().detect(in: .text(json))
        XCTAssertEqual(found.filter { $0.type == .name }.map(\.value), [#"O\"Brien, Margaret"#])
        XCTAssertEqual(found.filter { $0.type == .mrn }.map(\.value), ["88214309"])
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
