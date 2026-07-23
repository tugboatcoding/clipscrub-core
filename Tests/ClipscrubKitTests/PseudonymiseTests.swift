import CryptoKit
import XCTest
@testable import ClipscrubKit

final class PseudonymiseTests: XCTestCase {
    private let fixedKey = SymmetricKey(data: Data(repeating: 0x2b, count: 32))

    func testKeyedTokenIsStableAndValueFree() async throws {
        let pseudo = Pseudonymiser(key: fixedKey, width: 4)
        let token = pseudo.token(for: "a@b.com", type: .email)
        let text = try await RedactionPipeline.makeDefault()
            .run(text: "reach a@b.com or a@b.com", mode: .pseudonymise, pseudonymiser: pseudo)
            .redactedText
        XCTAssertTrue(text.contains(token))
        XCTAssertFalse(text.contains("[EMAIL_1]"))
        XCTAssertEqual(text.components(separatedBy: token).count - 1, 2)
        XCTAssertFalse(token.contains("a@b.com"))
    }

    func testStableAcrossInstancesDistinctForDistinctValues() {
        let a = Pseudonymiser(key: fixedKey).token(for: "a@b.com", type: .email)
        let aAgain = Pseudonymiser(key: fixedKey).token(for: "a@b.com", type: .email)
        let b = Pseudonymiser(key: fixedKey).token(for: "c@d.com", type: .email)
        XCTAssertEqual(a, aAgain)
        XCTAssertNotEqual(a, b)
    }
}
