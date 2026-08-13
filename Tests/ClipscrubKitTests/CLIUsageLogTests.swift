import XCTest
@testable import ClipscrubKit

final class CLIUsageLogTests: XCTestCase {
    private var dir: URL!
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("clitest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAppendAndLoadRoundTrip() throws {
        let record = CLIUsageRecord(timestamp: t0, mode: .redact, command: .text,
                                    entityCounts: ["ssn": 1, "email": 2])
        try CLIUsageLog.append(record, in: dir)
        let loaded = CLIUsageLog.loadRecords(in: dir)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].command, .text)
        XCTAssertEqual(loaded[0].mode, .redact)
        XCTAssertEqual(loaded[0].entityCounts, ["ssn": 1, "email": 2])
        XCTAssertEqual(loaded[0].totalCount, 3)
    }

    func testConfigDefaultsOffAndRoundTrips() throws {
        XCTAssertNil(CLIUsageLog.loadConfig(in: dir)) // absent ⇒ off (opt-in)
        try CLIUsageLog.writeConfig(CLILogConfig(loggingEnabled: true), in: dir)
        XCTAssertEqual(CLIUsageLog.loadConfig(in: dir)?.loggingEnabled, true)
    }

    func testRetentionDropsOldKeepsRecent() throws {
        try CLIUsageLog.append(CLIUsageRecord(timestamp: t0.addingTimeInterval(-100 * 86_400),
                                              mode: .redact, command: .text, entityCounts: ["ssn": 1]), in: dir)
        try CLIUsageLog.append(CLIUsageRecord(timestamp: t0.addingTimeInterval(-1 * 86_400),
                                              mode: .redact, command: .doc, entityCounts: ["name": 1]), in: dir)
        let kept = try CLIUsageLog.applyRetention(days: 90, now: t0, in: dir)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].command, .doc)
        XCTAssertEqual(CLIUsageLog.loadRecords(in: dir).count, 1) // pruned on disk too
    }

    func testClearEmptiesTheLog() throws {
        try CLIUsageLog.append(CLIUsageRecord(timestamp: t0, mode: .redact, command: .image,
                                              entityCounts: ["face": 1]), in: dir)
        try CLIUsageLog.clearRecords(in: dir)
        XCTAssertTrue(CLIUsageLog.loadRecords(in: dir).isEmpty)
    }

    /// The PHI-at-rest invariant: counts derived from REAL detection over raw input must persist with
    /// no raw value on disk. Hand-built counts would be tautological — this drives the actual
    /// detection → entityCounts → serialize chain, so it also guards against a future raw-text field.
    func testNoRawValuesInPersistedLog() async throws {
        let result = try await RedactionPipeline.makeDefault()
            .run(text: "patient SSN 123-45-6789", mode: .redact, pseudonymiser: nil)
        let record = CLIUsageRecord(timestamp: t0, mode: .redact, command: .text,
                                    entityCounts: entityCounts(result.entities))
        XCTAssertGreaterThan(record.totalCount, 0) // detection actually fired
        try CLIUsageLog.append(record, in: dir)
        let bytes = try Data(contentsOf: dir.appendingPathComponent(CLIUsageLog.historyFileName))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("123-45-6789"))
    }

    /// A single undecodable ELEMENT (e.g. a newer CLI's unknown command) is skipped, not fatal — the
    /// good records survive and the file is not treated as corrupt.
    func testUnknownElementSkippedNotFatal() throws {
        let url = dir.appendingPathComponent(CLIUsageLog.historyFileName)
        let json = """
        [{"id":"\(UUID().uuidString)","timestamp":"2023-11-14T22:13:20Z","mode":"redact","command":"video","entityCounts":{"ssn":1}},
         {"id":"\(UUID().uuidString)","timestamp":"2023-11-14T22:13:20Z","mode":"redact","command":"text","entityCounts":{"name":1}}]
        """
        try Data(json.utf8).write(to: url)
        let loaded = CLIUsageLog.loadRecords(in: dir)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.command, .text)
    }

    /// A top-level-undecodable file is preserved aside, never clobbered, when the next write lands.
    func testCorruptFilePreservedNotClobbered() throws {
        let url = dir.appendingPathComponent(CLIUsageLog.historyFileName)
        try Data("not json at all".utf8).write(to: url)
        try CLIUsageLog.append(CLIUsageRecord(timestamp: t0, mode: .redact, command: .text,
                                              entityCounts: ["ssn": 1]), in: dir)
        XCTAssertEqual(CLIUsageLog.loadRecords(in: dir).count, 1) // fresh log, not wiped-then-thrown
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(CLIUsageLog.historyFileName + ".corrupt").path))
    }
}
