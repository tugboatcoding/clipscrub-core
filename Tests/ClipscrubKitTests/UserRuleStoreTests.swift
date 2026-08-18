import XCTest
@testable import ClipscrubKit

final class UserRuleStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rulestest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRoundTripAndAbsentFileIsEmptyNotAnError() throws {
        XCTAssertEqual(UserRuleStore.load(in: dir).count, 0, "no file yet is not a failure")
        let rules = [
            UserRule(name: "Customer ID", pattern: #"ZX\d{5}"#),
            UserRule(name: "Ticket", pattern: #"TCK-\d+"#, isEnabled: false, caseInsensitive: true),
        ]
        try UserRuleStore.save(rules, in: dir)
        let loaded = UserRuleStore.load(in: dir)
        XCTAssertEqual(loaded, rules, "id, name, pattern, enabled and case flag all survive")
    }

    /// The bytes are rules the user typed by hand, so an unreadable file is moved aside rather than
    /// overwritten. Losing them to a decode error nobody saw is worse than leaving a file on disk.
    func testCorruptFileIsPreservedNotClobbered() throws {
        let url = dir.appendingPathComponent(UserRuleStore.fileName)
        try Data("{ not json".utf8).write(to: url)
        XCTAssertEqual(UserRuleStore.load(in: dir).count, 0)

        try UserRuleStore.save([UserRule(name: "Fresh", pattern: "ZX1")], in: dir)
        let backup = dir.appendingPathComponent(UserRuleStore.fileName + ".corrupt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "the old bytes are kept")
        XCTAssertEqual(UserRuleStore.load(in: dir).map(\.name), ["Fresh"])
    }

    /// One malformed entry must not take the rest of the file with it.
    func testOneBadEntrySkippedRestSurvive() throws {
        let json = """
        { "version": 1, "rules": [
          { "id": "\(UUID().uuidString)", "name": "Good", "pattern": "ZX1", "isEnabled": true, "caseInsensitive": false },
          { "nonsense": true },
          { "id": "\(UUID().uuidString)", "name": "Also good", "pattern": "ZX2", "isEnabled": true, "caseInsensitive": false }
        ] }
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent(UserRuleStore.fileName))
        XCTAssertEqual(UserRuleStore.load(in: dir).map(\.name), ["Good", "Also good"])
    }

    /// A file from a newer build may use fields this one would drop on the next save, so it is left
    /// alone rather than half-read and rewritten.
    func testFutureVersionIsNotHalfRead() throws {
        let json = """
        { "version": \(UserRuleStore.currentVersion + 1), "rules": [
          { "id": "\(UUID().uuidString)", "name": "Newer", "pattern": "ZX1", "isEnabled": true, "caseInsensitive": false }
        ] }
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent(UserRuleStore.fileName))
        XCTAssertEqual(UserRuleStore.load(in: dir).count, 0)
        XCTAssertTrue(UserRuleStore.loadDetailed(in: dir).corrupt, "so a save preserves it instead of overwriting")
    }

    func testCLIDirectoryUsesTheSharedUsageLogGroup() {
        XCTAssertTrue(UserRuleStore.directForCLI().path.contains(CLIUsageLog.groupID))
    }

    // MARK: Import / export

    func testExportImportRoundTrip() throws {
        let rules = [
            UserRule(name: "Customer ID", pattern: #"ZX\d{5}"#),
            UserRule(name: "Ticket", pattern: #"TCK-\d+"#, isEnabled: false, caseInsensitive: true),
        ]
        let data = try UserRuleStore.exportData(rules)
        let decoded = try UserRuleStore.decode(data)
        XCTAssertEqual(decoded, rules, "an exported file is a valid custom-rules.json — round-trips byte-for-byte in shape")
    }

    /// An exported file IS a `custom-rules.json`: what `save` writes and what `decode` reads must
    /// agree on every field, or importing an exported file would silently drop the caller's data.
    func testExportedDataLoadsThroughTheOrdinaryFilePath() throws {
        let rules = [UserRule(name: "Fresh", pattern: "ZX1")]
        let data = try UserRuleStore.exportData(rules)
        try data.write(to: dir.appendingPathComponent(UserRuleStore.fileName))
        XCTAssertEqual(UserRuleStore.load(in: dir), rules)
    }

    /// One case table for the three ways `decode`/`decodeDetailed` treat a hand-written payload
    /// differently from a well-formed one — a future format version, one malformed entry among
    /// good ones, and a decodable-but-uncompilable pattern. Each asserts a different thing about the
    /// same shape of input, so one parameterized test reads better than three near-duplicates.
    func testDecodeCases() throws {
        struct Case {
            let name: String
            let json: String
            /// Set only for the case that must throw; every other case asserts against a decode.
            let expectFutureVersion: Int?
            let expectRuleNames: [String]?
            let expectTotal: Int?
        }

        let unbalancedID = UUID()
        let cases = [
            Case(
                name: "future version is rejected outright, same gate as loadDetailed",
                json: """
                { "version": \(UserRuleStore.currentVersion + 1), "rules": [
                  { "id": "\(UUID().uuidString)", "name": "Newer", "pattern": "ZX1", "isEnabled": true, "caseInsensitive": false }
                ] }
                """,
                expectFutureVersion: UserRuleStore.currentVersion + 1,
                expectRuleNames: nil,
                expectTotal: nil
            ),
            Case(
                name: "one malformed entry is dropped, total still counts it — the N-of-M gap",
                json: """
                { "version": 1, "rules": [
                  { "id": "\(UUID().uuidString)", "name": "Good", "pattern": "ZX1", "isEnabled": true, "caseInsensitive": false },
                  { "nonsense": true },
                  { "id": "\(UUID().uuidString)", "name": "Also good", "pattern": "ZX2", "isEnabled": true, "caseInsensitive": false }
                ] }
                """,
                expectFutureVersion: nil,
                expectRuleNames: ["Good", "Also good"],
                expectTotal: 3
            ),
            Case(
                name: "an uncompilable pattern still decodes — validity is a detector-time concern",
                json: """
                { "version": 1, "rules": [
                  { "id": "\(unbalancedID.uuidString)", "name": "Unbalanced", "pattern": "[unclosed", "isEnabled": true, "caseInsensitive": false }
                ] }
                """,
                expectFutureVersion: nil,
                expectRuleNames: ["Unbalanced"],
                expectTotal: 1
            ),
        ]

        for testCase in cases {
            let data = Data(testCase.json.utf8)
            if let expectFutureVersion = testCase.expectFutureVersion {
                XCTAssertThrowsError(try UserRuleStore.decode(data), testCase.name) { error in
                    guard case UserRuleStore.ImportError.futureVersion(let version) = error else {
                        return XCTFail("\(testCase.name): expected futureVersion, got \(error)")
                    }
                    XCTAssertEqual(version, expectFutureVersion, testCase.name)
                }
                continue
            }
            let detail = try UserRuleStore.decodeDetailed(data)
            XCTAssertEqual(detail.rules.map(\.name), testCase.expectRuleNames, testCase.name)
            XCTAssertEqual(detail.total, testCase.expectTotal, testCase.name)
        }

        // The uncompilable-pattern case decoded — this is the detector-time half of that assertion.
        let unbalanced = try UserRuleStore.decode(Data(cases[2].json.utf8))
        XCTAssertEqual(UserRuleDetector(rules: unbalanced).rejected.map(\.id), [unbalancedID])
    }

    /// A floor against a hand-crafted or corrupted file turning "decode a shared rules file" into
    /// building and compiling an enormous array. Built programmatically rather than as a literal —
    /// the count is the point, not any particular rule's shape.
    func testDecodeRejectsAnAbsurdRuleCount() throws {
        let entries = (0...UserRuleStore.maxImportedRuleCount).map { i in
            #"{ "id": "\#(UUID().uuidString)", "name": "R\#(i)", "pattern": "ZX\#(i)", "isEnabled": true, "caseInsensitive": false }"#
        }.joined(separator: ",")
        let json = #"{ "version": 1, "rules": [\#(entries)] }"#

        XCTAssertThrowsError(try UserRuleStore.decode(Data(json.utf8))) { error in
            guard case UserRuleStore.ImportError.tooManyRules(let count) = error else {
                return XCTFail("expected tooManyRules, got \(error)")
            }
            XCTAssertEqual(count, UserRuleStore.maxImportedRuleCount + 1)
        }
    }
}
