import XCTest
@testable import ClipscrubKit

// The Foundation Models tier over-redacted on context: ordinary words next to a real identifier
// were flagged as OTHER/NAME, and the flags shifted with unrelated surrounding words. The gate
// (DetectionEngine.gateModelFindings) trims that tier without touching the deterministic floor.
// The model is non-deterministic and unavailable in CI, so the gate is tested directly with
// synthetic findings. The safety focus is the never-under-redact boundary: a deterministic finding
// is never dropped, and real identifiers (multi-word names, names that double as common words,
// values with digits) survive the model-tier trims.
final class ModelGateTests: XCTestCase {
    private static let text = "hey my ssn is this: SSN 123-45-6789"

    private static func range(_ substring: String) -> Range<String.Index> {
        text.range(of: substring)!
    }

    private static func model(_ type: EntityType, _ value: String, confidence: Double) -> DetectedEntity {
        DetectedEntity(type: type, value: value, confidence: confidence,
                       source: .foundationModel, locus: .text(range(value)))
    }

    private static func regex(_ type: EntityType, _ value: String) -> DetectedEntity {
        DetectedEntity(type: type, value: value, confidence: 0.95,
                       source: .regex, locus: .text(range(value)))
    }

    func testGateDropsUncorroboratedGenericOther() {
        let gated = DetectionEngine.gateModelFindings([
            Self.regex(.ssn, "123-45-6789"),
            Self.model(.other("OTHER"), "hey", confidence: 0.9),   // filler → drop
            Self.model(.other("OTHER"), "this", confidence: 0.9),  // filler → drop
        ])
        XCTAssertEqual(gated.count, 1)
        XCTAssertEqual(gated.first?.type, .ssn)
    }

    func testGateDropsLowConfidenceModelName() {
        let gated = DetectionEngine.gateModelFindings([
            Self.regex(.ssn, "123-45-6789"),
            Self.model(.name, "hey", confidence: 0.2),  // low-confidence phantom → drop
        ])
        XCTAssertFalse(gated.contains { $0.type == .name })
    }

    func testGateKeepsConfidentTypedModelFinding() {
        // The tier's real value: an unstructured name in prose the rules miss. A typed finding that
        // is a genuine content word (not filler) is kept even with no deterministic corroboration.
        let text = "spoke with Okonkwo yesterday"
        let name = DetectedEntity(type: .name, value: "Okonkwo", confidence: 0.9,
                                  source: .foundationModel, locus: .text(text.range(of: "Okonkwo")!))
        let gated = DetectionEngine.gateModelFindings([name])
        XCTAssertEqual(gated.count, 1)
        XCTAssertEqual(gated.first?.type, .name)
    }

    func testGateSuppressesFunctionWordNamePhantom() {
        // The measured failure: the model rates "hey my" as a NAME at confidence 1.0, so only the
        // structural function-word test (not confidence) can drop it.
        let phantom = DetectedEntity(type: .name, value: "hey my", confidence: 1.0,
                                     source: .foundationModel, locus: .text(Self.range("hey my")))
        XCTAssertTrue(DetectionEngine.gateModelFindings([phantom]).isEmpty)
    }

    func testFunctionWordGuardIsSafeForRealIdentifiers() {
        // Never suppress a value that carries an identifier: a real name, or anything with a digit.
        XCTAssertTrue(DetectionEngine.isAllFunctionWords("hey my this"))
        XCTAssertFalse(DetectionEngine.isAllFunctionWords("hey Smith"))       // content word
        XCTAssertFalse(DetectionEngine.isAllFunctionWords("ID A1234567"))     // has a digit
        XCTAssertFalse(DetectionEngine.isAllFunctionWords("John"))            // gazetteer name
        // Names that also read as common words must never be treated as filler — the exclusions the
        // function-word set depends on. A regression here would silently stop redacting a real name.
        for name in ["May", "Will", "Mark", "Grace", "Rose", "Dawn", "Hope", "Faith", "So", "He", "An", "No"] {
            XCTAssertFalse(DetectionEngine.isAllFunctionWords(name), "\(name) is a real name, not filler")
        }
    }

    func testGateNeverDropsDeterministicFindings() {
        // The floor is untouched: a deterministic finding survives regardless of source, confidence,
        // or value — even a .nlTagger name whose value is all function words at ~0 confidence.
        let text = "the"
        for source in [DetectionSource.nlTagger, .dataDetector, .regex, .vision] {
            let e = DetectedEntity(type: .name, value: "the", confidence: 0.01,
                                   source: source, locus: .text(text.startIndex..<text.endIndex))
            XCTAssertEqual(DetectionEngine.gateModelFindings([e]).count, 1, "dropped a \(source) finding")
        }
    }

    func testGateKeepsCorroboratedGenericOther() {
        // A model OTHER that overlaps a deterministic span is real (redundant, but kept) — the
        // keep-branch of the corroboration rule, distinct from the uncorroborated-drop case above.
        let text = "case XJ42Q here"
        let r = text.range(of: "XJ42Q")!
        let regexHit = DetectedEntity(type: .account, value: "XJ42Q", confidence: 0.9, source: .regex, locus: .text(r))
        let modelOther = DetectedEntity(type: .other("OTHER"), value: "XJ42Q", confidence: 0.9,
                                        source: .foundationModel, locus: .text(r))
        let gated = DetectionEngine.gateModelFindings([regexHit, modelOther])
        XCTAssertTrue(gated.contains { $0.source == .foundationModel }, "corroborated OTHER was dropped")
    }

    func testGateKeepsMultiWordNameAndFloorBoundary() {
        // A genuine multi-word name (the case structurally nearest the "hey my" phantom) must survive,
        // and a typed finding exactly at the confidence floor is kept (floor is `< floor` drops).
        let text = "spoke with Sarah Connor at 0.5"
        let name = DetectedEntity(type: .name, value: "Sarah Connor", confidence: 0.9,
                                  source: .foundationModel, locus: .text(text.range(of: "Sarah Connor")!))
        XCTAssertEqual(DetectionEngine.gateModelFindings([name]).count, 1)
        let atFloor = DetectedEntity(type: .name, value: "Sarah Connor", confidence: DetectionEngine.modelConfidenceFloor,
                                     source: .foundationModel, locus: .text(text.range(of: "Sarah Connor")!))
        XCTAssertEqual(DetectionEngine.gateModelFindings([atFloor]).count, 1, "finding at the floor must be kept")
    }

    func testGateNeverTouchesDeterministicLayers() {
        // Quasi-identifiers (age/sex/domain) ride .other(...) from the regex layer — they must
        // survive regardless of confidence, unlike the model's generic OTHER.
        let low = DetectedEntity(type: .other("age"), value: "hey", confidence: 0.1,
                                 source: .regex, locus: .text(Self.range("hey")))
        let gated = DetectionEngine.gateModelFindings([low])
        XCTAssertEqual(gated.count, 1)
        XCTAssertEqual(gated.first?.type, .other("age"))
    }

    // MARK: - Off-script categories

    func testGateJudgesAnInventedCategoryOnItsValue() {
        // Measured: `PHQ-9 score was 14.` came back under a `PHIFinding` category, which is not in
        // llm-prompt.json, tokenising as [PHIFINDING_1] over the number 14.
        let text = "PHQ-9 score was 14."
        for value in ["14", "PHQ-9"] {
            let invented = DetectedEntity(type: .other("PHIFinding"), value: value, confidence: 0.9,
                                          source: .foundationModel, locus: .text(text.range(of: value)!))
            XCTAssertTrue(DetectionEngine.gateModelFindings([invented], in: text).isEmpty, "kept: \(value)")
        }
    }

    func testAnInventedCategoryOnARealNameIsStillARealName() {
        // The reason an invented label is judged on the value rather than dropped: one measured run
        // filed a Vietnamese name no deterministic layer reaches under `PHIFinding`. Dropping every
        // invented label ships that name in the clear.
        let text = "Nguyễn Thị Hương,2026-03-04,A0938271"
        let name = DetectedEntity(type: .other("PHIFinding"), value: "Nguyễn Thị Hương", confidence: 0.9,
                                  source: .foundationModel, locus: .text(text.range(of: "Nguyễn Thị Hương")!))
        XCTAssertEqual(DetectionEngine.gateModelFindings([name], in: text).count, 1)
    }

    func testCategoriesThePromptOffersAreNotTreatedAsOffScript() {
        // ZIP, AGE, SEX and the rest have no EntityType case, so they ride .other(...) exactly like an
        // invented label. The prompt offered them, so they must not be gated as one.
        for offered in ["ZIP", "AGE", "SEX", "RACE", "MARITAL"] {
            XCTAssertFalse(DetectionEngine.isOffScriptCategory(.other(offered)), "\(offered) is on the prompt")
        }
        XCTAssertTrue(DetectionEngine.isOffScriptCategory(.other("PHIFinding")))
        // OTHER is on the prompt and keeps its own, older rule — corroboration, whatever the value.
        XCTAssertFalse(DetectionEngine.isOffScriptCategory(.other("OTHER")))
    }

    // MARK: - Instrument acronyms

    func testGateDropsUncorroboratedInstrumentAcronym() {
        let text = "Seen by MMSE today"
        let acronym = DetectedEntity(type: .name, value: "MMSE", confidence: 0.9,
                                     source: .foundationModel, locus: .text(text.range(of: "MMSE")!))
        XCTAssertTrue(DetectionEngine.gateModelFindings([acronym], in: text).isEmpty)
    }

    func testGateKeepsCorroboratedAllCapsSurname() {
        // `Patient SMITH arrived.` is caught by the deterministic name layers on their own, so the
        // model's duplicate is corroborated and survives. This is the guard on the rule above: the
        // acronym shape and an all-caps surname are the same characters.
        let text = "Patient SMITH arrived"
        let r = text.range(of: "SMITH")!
        let floor = DetectedEntity(type: .name, value: "SMITH", confidence: 0.6, source: .nlTagger, locus: .text(r))
        let model = DetectedEntity(type: .name, value: "SMITH", confidence: 0.9, source: .foundationModel, locus: .text(r))
        XCTAssertTrue(DetectionEngine.gateModelFindings([floor, model], in: text).contains { $0.source == .foundationModel })
    }

    func testGateDropsAnUncorroboratedNumberTypedAsAName() {
        // Measured: `Sessions began in 2026.` came back with 2026 as a NAME. A bare year carries no
        // identity, and Safe Harbor permits it.
        let text = "Sessions began in 2026."
        let year = DetectedEntity(type: .name, value: "2026", confidence: 0.9,
                                  source: .foundationModel, locus: .text(text.range(of: "2026")!))
        XCTAssertTrue(DetectionEngine.gateModelFindings([year], in: text).isEmpty)
    }

    func testGateKeepsARecordNumberTheModelReadsAsAName() {
        // The guard on the rule above: the model types a record number NAME too, and the rules that
        // know its shape reach it, so corroboration keeps it.
        let text = "The chart lists 88-40021 under record."
        let r = text.range(of: "88-40021")!
        let floor = DetectedEntity(type: .mrn, value: "88-40021", confidence: 0.9, source: .regex, locus: .text(r))
        let model = DetectedEntity(type: .name, value: "88-40021", confidence: 0.9, source: .foundationModel, locus: .text(r))
        XCTAssertTrue(DetectionEngine.gateModelFindings([floor, model], in: text).contains { $0.source == .foundationModel })
    }

    func testTheBareNumberRuleIsNarrowerThanNoLettersInIt() {
        // "any NAME with no letters in it" reads as the same rule and costs a real identifier: a bare
        // CSV line of `090-1234-5678` is a phone the model alone catches, and nothing corroborates it.
        XCTAssertTrue(DetectionEngine.isShortBareNumber("2026"))
        XCTAssertTrue(DetectionEngine.isShortBareNumber("14"))
        for value in ["090-1234-5678", "88-40021", "402-11-8853", "A0938271", "2026-03-04", "",
                      "4471209", "90218473"] {   // a bare member number is long, and identifies someone
            XCTAssertFalse(DetectionEngine.isShortBareNumber(value), "\(value) must not be dropped")
        }
        // And the whole rule, end to end: an uncorroborated phone the model typed NAME survives.
        let text = "090-1234-5678"
        let phone = DetectedEntity(type: .name, value: text, confidence: 0.9, source: .foundationModel,
                                   locus: .text(text.startIndex..<text.endIndex))
        XCTAssertEqual(DetectionEngine.gateModelFindings([phone], in: text).count, 1)
    }

    func testInstrumentAcronymShapeSpareRealIdentifiers() {
        for code in ["MMSE", "PHQ-9", "GAD-7", "CAGE"] {
            XCTAssertTrue(DetectionEngine.isInstrumentAcronym(code), "\(code) is an instrument code")
        }
        // A member ID the model alone catches — no deterministic layer reaches it, so a rule that
        // treated any digit in a name as disqualifying would lose it outright.
        XCTAssertFalse(DetectionEngine.isInstrumentAcronym("HPX-4471209"))
        XCTAssertFalse(DetectionEngine.isInstrumentAcronym("SARAH"))     // gazetteer name
        XCTAssertFalse(DetectionEngine.isInstrumentAcronym("Okonkwo"))   // not all caps
    }

    // MARK: - A name that runs into prose

    func testGateDropsNameSpanThatRanIntoProse() {
        // Measured: `Rogerian therapy used.` arrived as one NAME. Cut back to what can still be a
        // name, then ask the floor. One word with nothing beside it on the floor is not a person.
        for (text, value) in [
            ("Rogerian therapy used.", "Rogerian therapy"),
            ("Patient has Parkinson's disease.", "Parkinson's disease"),
        ] {
            let overrun = DetectedEntity(type: .name, value: value, confidence: 0.9,
                                         source: .foundationModel, locus: .text(text.range(of: value)!))
            XCTAssertTrue(DetectionEngine.gateModelFindings([overrun], in: text).isEmpty, "kept: \(value)")
        }
    }

    func testAnOvershotSpanOfTwoWordsIsKeptEvenWithNothingOnTheFloor() {
        // The other half of the same rule, and the more dangerous half. Two capitalised words are a
        // name read too far, and the model tier is the only layer that reaches some of them — a bare
        // roster line, a non-Latin name, a name in a column. Dropping the finding because the floor
        // is silent is how the surname ships in the clear.
        for (text, value, kept) in [
            ("spoke with Sarah Connor met the therapist", "Sarah Connor met", "Sarah Connor"),
            ("Maria Gonzalez was seen today", "Maria Gonzalez was seen", "Maria Gonzalez"),
            ("Maria de los Santos attended", "Maria de los Santos attended", "Maria de los Santos"),
        ] {
            let overrun = DetectedEntity(type: .name, value: value, confidence: 0.9,
                                         source: .foundationModel, locus: .text(text.range(of: value)!))
            let gated = DetectionEngine.gateModelFindings([overrun], in: text)
            XCTAssertEqual(gated.first?.value, kept, "lost \(kept) from: \(value)")
        }
    }

    func testGateKeepsUncorroboratedSurnamesTheGazetteerDoesNotHold() {
        // `given-names.json` holds given names only, so `smith`, `jones`, `lee`, `kim`, `ng` and `wu`
        // are all absent from it. An all-caps surname on a bare roster line has nothing corroborating
        // it, and the acronym rule must not be what decides.
        for surname in ["SMITH", "JONES", "LEE", "KIM", "NG", "WU"] {
            let text = "\(surname)\n"
            let model = DetectedEntity(type: .name, value: surname, confidence: 0.9, source: .foundationModel,
                                       locus: .text(text.range(of: surname)!))
            let floor = DetectedEntity(type: .name, value: surname, confidence: 0.5, source: .nlTagger,
                                       locus: .text(text.range(of: surname)!))
            // Corroborated by any layer at all, even a span that only overlaps.
            XCTAssertFalse(DetectionEngine.gateModelFindings([floor, model], in: text)
                .filter { $0.source == .foundationModel }.isEmpty, "dropped \(surname)")
        }
    }

    func testTruncationRefusesAHeadThatDoesNotStartTheSpan() {
        // The model copies its value out of the input, but a substituted apostrophe or a decomposed
        // accent makes the character count lie about where the name ends. Re-anchoring on that lie
        // moves the redaction off the name, so the finding is kept whole instead.
        let text = "O\u{2019}Brien arrived and left"
        let value = "O'Brien arrived"   // straight apostrophe, so it is not a prefix of the source
        let overrun = DetectedEntity(type: .name, value: value, confidence: 0.9, source: .foundationModel,
                                     locus: .text(text.startIndex..<text.index(text.startIndex, offsetBy: 15)))
        let gated = DetectionEngine.gateModelFindings([overrun], in: text)
        XCTAssertEqual(gated.count, 1, "a head that does not start the span must leave the finding alone")
    }

    func testGateDropsProseOverrunWhateverCategoryTheModelUsed() {
        // The same phrase came back as DOB on one run and ADDRESS on another, so a rule scoped to
        // NAME would catch it only some of the time.
        let text = "Patient has Parkinson's disease."
        for type in [EntityType.dateOfBirth, .address, .name] {
            let overrun = DetectedEntity(type: type, value: "Parkinson's disease", confidence: 0.9,
                                         source: .foundationModel, locus: .text(text.range(of: "Parkinson's disease")!))
            XCTAssertTrue(DetectionEngine.gateModelFindings([overrun], in: text).isEmpty, "kept as \(type)")
        }
    }

    func testProseOverrunIsTruncatedNotDroppedWhenTheNameIsReal() {
        // The reason this truncates instead of dropping: the model overshooting a real name must not
        // uncover it. The name survives and only the prose it ran into is given back.
        let text = "Yoko Tanaka attended the clinic"
        let name = text.range(of: "Yoko Tanaka")!
        let floor = DetectedEntity(type: .name, value: "Yoko Tanaka", confidence: 0.6, source: .nlTagger, locus: .text(name))
        let overrun = DetectedEntity(type: .name, value: "Yoko Tanaka attended", confidence: 0.9,
                                     source: .foundationModel, locus: .text(text.range(of: "Yoko Tanaka attended")!))
        let gated = DetectionEngine.gateModelFindings([floor, overrun], in: text)
        let kept = gated.first { $0.source == .foundationModel }
        XCTAssertEqual(kept?.value, "Yoko Tanaka")
        // The span has to shrink with the value, or the redactor still covers the word after it.
        XCTAssertEqual(kept?.offsets(in: text)?.length, "Yoko Tanaka".count)
        XCTAssertEqual(kept?.offsets(in: text)?.start, 0)
    }

    func testProseOverrunLeavesRealNamesAlone() {
        // Values that must never be read as a name plus prose. The first two have no upper-case
        // token at all, which is what keeps scripts without letter case out of this rule.
        for value in ["田中 陽子", "maria gonzalez", "Anna van der Berg", "Sarah Connor", "Okonkwo"] {
            XCTAssertNil(DetectionEngine.leadingNameRun(of: value), "\(value) was cut")
        }
        XCTAssertEqual(DetectionEngine.leadingNameRun(of: "Rogerian therapy"), "Rogerian")
        XCTAssertEqual(DetectionEngine.leadingNameRun(of: "Sarah Connor met the therapist"), "Sarah Connor")
    }

    func testGateKeepsAModelOnlyMemberIDTypedAsAName() {
        // Measured model-only catch: --no-llm leaves `HPX-4471209` in the clear, and the model types
        // it NAME on some runs. Nothing above may touch it.
        let text = "She gave her card as HPX-4471209 at reception"
        let id = DetectedEntity(type: .name, value: "HPX-4471209", confidence: 0.9,
                                source: .foundationModel, locus: .text(text.range(of: "HPX-4471209")!))
        XCTAssertEqual(DetectionEngine.gateModelFindings([id], in: text).count, 1)
    }

    // MARK: - Document-role words

    func testGateSuppressesDocumentRoleWordsReadAsNames() {
        // Measured: `Sessions began in 2026.` tagged `Sessions` as a NAME. The words a note uses for
        // its own roles and objects are never the identifier.
        for (text, value) in [("Sessions began in 2026.", "Sessions"), ("Patient has improved.", "Patient")] {
            let phantom = DetectedEntity(type: .name, value: value, confidence: 0.95,
                                         source: .foundationModel, locus: .text(text.range(of: value)!))
            XCTAssertTrue(DetectionEngine.gateModelFindings([phantom], in: text).isEmpty, "kept: \(value)")
        }
        // …and never when a real name sits beside one.
        XCTAssertFalse(DetectionEngine.isAllFunctionWords("Patient Sarah Chen"))
    }

    func testDeterministicFloorAlwaysRedactsSSN() async throws {
        // No-LLM path over the reported strings: the real SSN must always redact regardless of
        // surrounding words. The floor may over-flag odd words as names (a safe over-redaction — the
        // NLTagger title-cased pass errs toward catching names); the OTHER/NAME *instability* the
        // user hit was the model tier, gated separately above. Recall is the guarantee tested here.
        for input in [
            "hey my ssn is SSN 123-45-6789",
            "hey my ssn is this: SSN 123-45-6789",
            "fox trot dippy dappy. hey my ssn is this: SSN 123-45-6789",
        ] {
            let result = try await RedactionPipeline.makeDefault().run(text: input)
            XCTAssertTrue(result.redactedText.contains("[SSN_1]"), "SSN not redacted in: \(input)")
            XCTAssertFalse(result.redactedText.contains("123-45-6789"), "SSN leaked in: \(input)")
        }
    }
}
