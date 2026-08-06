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
