import XCTest
@testable import ClipscrubKit

final class VisionRecognitionLanguagesTests: XCTestCase {
    func testResolveFallsBackToEnglishOnEmptySupported() {
        XCTAssertEqual(VisionTextRecognizer.resolve(preferred: ["en-US", "ja-JP"], supported: []), ["en-US"])
    }

    func testResolveFallsBackToEnglishOnDisjointSupported() {
        // Nothing preferred is in the supported set, so this is the same failure mode as an empty
        // set — the fallback exists for exactly this shape too.
        XCTAssertEqual(
            VisionTextRecognizer.resolve(preferred: ["ja-JP", "zh-Hans"], supported: ["fr-FR", "de-DE"]),
            ["en-US"]
        )
    }

    func testResolvePreservesPreferredOrderOnPartialOverlap() {
        XCTAssertEqual(
            VisionTextRecognizer.resolve(preferred: ["ja-JP", "en-US", "ar-SA"], supported: ["en-US", "ar-SA"]),
            ["en-US", "ar-SA"]
        )
    }

    func testResolveKeepsEveryLanguageOnFullOverlap() {
        let preferred = ["en-US", "es-ES", "ja-JP"]
        XCTAssertEqual(VisionTextRecognizer.resolve(preferred: preferred, supported: Set(preferred)), preferred)
    }

    func testLiveRecognitionLanguagesIsNonEmptyAndWithinPreferred() {
        // Exercises the real Vision probe (not the pure resolve() above), so this is the one check
        // that would catch a probe API change silently returning something unexpected.
        let resolved = VisionTextRecognizer.recognitionLanguages
        XCTAssertFalse(resolved.isEmpty)
        let allowed = Set(VisionTextRecognizer.preferredRecognitionLanguages + ["en-US"])
        XCTAssertTrue(resolved.allSatisfy { allowed.contains($0) },
                      "recognitionLanguages returned something outside the preferred list: \(resolved)")
    }
}
