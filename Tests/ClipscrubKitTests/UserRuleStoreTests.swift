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
}
