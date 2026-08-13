import XCTest
@testable import ClipscrubKit

/// `ZX\d{5}` throughout, because the bundled layers leave `ZX40213` alone. A `CUST-` fixture does
/// not — NLTagger reads it as a personal name — so it is used only where that collision is the point.
final class UserRuleTests: XCTestCase {
    private let good = UserRule(name: "Customer ID", pattern: #"ZX\d{5}"#)
    private let broken = UserRule(name: "Unclosed group", pattern: "ZX(")

    func testInvalidPatternIsRejectedWithoutThrowing() {
        let detector = UserRuleDetector(rules: [good, broken])
        XCTAssertEqual(detector.rejected.map(\.name), ["Unclosed group"])
        XCTAssertFalse(detector.rejected[0].reason.isEmpty, "the regex engine's own message is kept")
        XCTAssertFalse(detector.isEmpty, "the rule that compiled is still there")
    }

    func testOneBadPatternDoesNotDropTheGoodOnes() async throws {
        let hits = try await UserRuleDetector(rules: [good, broken]).detect(in: .text("ref ZX40213 filed"))
        XCTAssertEqual(hits.map(\.value), ["ZX40213"])
    }

    /// The reason this detector exists. `RegexRulesetDetector` throws out of its initialiser on a bad
    /// pattern, so merging user rules into the bundled ruleset would mean one typo leaves the app with
    /// no pipeline at all — no SSN, no email, no MRN.
    func testBrokenUserRuleLeavesTheBundledLayersIntact() async throws {
        let out = try await RedactionPipeline.makeDefault(userRules: [broken])
            .run(text: "SSN 123-45-6789 mail a@b.com").redactedText
        XCTAssertEqual(out, "SSN [SSN_1] mail [EMAIL_1]")
    }

    /// The no-argument call must stay byte-identical whatever rules sit on the machine. Otherwise
    /// the same text redacts differently for two developers.
    func testMakeDefaultWithNoUserRulesIsUnchanged() async throws {
        let out = try await RedactionPipeline.makeDefault().run(text: "SSN 123-45-6789").redactedText
        XCTAssertEqual(out, "SSN [SSN_1]")
    }

    func testHitsTokeniseAsCustomAndDisabledRulesNeverFire() async throws {
        let on = try await RedactionPipeline.makeDefault(userRules: [good])
            .run(text: "id ZX40213 and ZX99001").redactedText
        XCTAssertEqual(on, "id [CUSTOM_1] and [CUSTOM_2]")

        let off = UserRule(name: "Parked", pattern: #"ZX\d{5}"#, isEnabled: false)
        let out = try await RedactionPipeline.makeDefault(userRules: [off]).run(text: "id ZX40213").redactedText
        XCTAssertEqual(out, "id ZX40213")
    }

    func testCaseInsensitiveIsOptIn() async throws {
        let sensitive = UserRule(name: "Exact", pattern: #"ZX\d{5}"#)
        let insensitive = UserRule(name: "Loose", pattern: #"ZX\d{5}"#, caseInsensitive: true)
        let text = "id zx40213"
        let strict = try await UserRuleDetector(rules: [sensitive]).detect(in: .text(text))
        let loose = try await UserRuleDetector(rules: [insensitive]).detect(in: .text(text))
        XCTAssertEqual(strict.count, 0)
        XCTAssertEqual(loose.map(\.value), ["zx40213"])
    }

    /// A user rule overlapping a bundled hit must take its own span whole. NLTagger reads `ref CUST`
    /// as one name here, so without the user rule the output is `[NAME_1]-40213` and the digits the
    /// user asked to remove are still on the page.
    ///
    /// The name token is not asserted as a literal. The spans overlap only in part, so the name
    /// survives over the characters the user rule did not claim — that is `resolveOverlaps` keeping
    /// the loser's remainder instead of uncovering it, and it belongs to the engine rather than to
    /// this fixture. `CUST-` carries the hyphen because `[CUSTOM_1]` contains `CUST` itself.
    func testUserRuleOverlappingABundledHitRemovesItsWholeSpan() async throws {
        let out = try await RedactionPipeline
            .makeDefault(userRules: [UserRule(name: "Customer ref", pattern: #"CUST-\d{5}"#)])
            .run(text: "ref CUST-40213 filed").redactedText
        XCTAssertTrue(out.contains("[CUSTOM_1]"), out)
        XCTAssertFalse(out.contains("40213"), out)
        XCTAssertFalse(out.contains("CUST-"), out)
    }

    /// The fail-open this feature nearly shipped with. A rule that runs out of time contributes none
    /// of its matches, so the text still holds what the user asked to remove — and before this the
    /// pipeline handed that back as a finished redaction.
    func testPipelineRefusesToReturnOutputAfterAnAbandonedRule() async throws {
        let bomb = String(repeating: "a", count: 40) + "!"
        let pipeline = try RedactionPipeline.makeDefault(userRules: [UserRule(name: "Runaway", pattern: "(a+)+$")])
        do {
            _ = try await pipeline.run(text: bomb).redactedText
            XCTFail("emitted output for a pass that abandoned a rule")
        } catch let error as UserRuleError {
            XCTAssertEqual(error, .timedOut(rule: "Runaway"))
        }
        // detect() is its own public entry point, so it fails too.
        do {
            _ = try await pipeline.detect(text: bomb)
            XCTFail("detect() reported success for a pass that abandoned a rule")
        } catch let error as UserRuleError {
            XCTAssertEqual(error, .timedOut(rule: "Runaway"))
        }
    }

    /// A timeout on one input must not poison the next. Draining at the start of each pass is what
    /// stops one enormous document failing every small one that follows it.
    func testAnAbandonedRuleDoesNotPoisonTheNextPass() async throws {
        let pipeline = try RedactionPipeline.makeDefault(userRules: [
            UserRule(name: "Runaway", pattern: "(a+)+$"),
            UserRule(name: "Customer ID", pattern: #"ZX\d{5}"#),
        ])
        _ = try? await pipeline.run(text: String(repeating: "a", count: 40) + "!")
        let out = try await pipeline.run(text: "id ZX40213").redactedText
        XCTAssertEqual(out, "id [CUSTOM_1]")
    }

    /// `NSRegularExpression` takes no timeout, so this asserts the `.reportProgress` deadline really
    /// bounds catastrophic backtracking rather than assuming it does.
    func testCatastrophicPatternIsAbandonedAndRecorded() async throws {
        let diagnostics = UserRuleDiagnostics()
        let detector = UserRuleDetector(
            rules: [UserRule(name: "Runaway", pattern: "(a+)+$")],
            diagnostics: diagnostics
        )
        let started = ContinuousClock.now
        let hits = try await detector.detect(in: .text(String(repeating: "a", count: 40) + "!"))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
        // A partial answer would redact the first few matches on a page and leave the rest readable,
        // which looks like a finished job.
        XCTAssertTrue(hits.isEmpty)
        let abandoned = await diagnostics.timedOutRules
        XCTAssertEqual(abandoned, ["Runaway"], "an abandoned rule must not vanish without a trace")
    }
}
