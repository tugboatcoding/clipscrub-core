import Foundation

// CLI usage log — a shared, metadata-only record of `clipscrub` CLI runs. A "host app" — any
// app that embeds ClipscrubKit, like the ClipScrub app itself — can read and surface it. Stores
// per-type COUNTS only (`entityCounts`), never a raw value or the output. Opt-in: the CLI writes
// nothing unless a host-written config enables it. The store lives in a shared container
// directory — see `directForCLI` / `containerForApp`.

/// Which CLI entry point produced a record.
public enum CLICommandKind: String, Codable, Sendable, CaseIterable {
    case text
    case image
    case doc
    case deid
}

/// Host-owned opt-in flag the CLI reads before logging. Absent file ⇒ logging off.
public struct CLILogConfig: Codable, Sendable, Equatable {
    public var loggingEnabled: Bool
    public init(loggingEnabled: Bool) {
        self.loggingEnabled = loggingEnabled
    }
}

/// One `clipscrub` invocation, metadata only. `entityCounts` is `EntityType.identifier`
/// → count (see `entityCounts(_:)`), the exact payload `--report` already emits.
public struct CLIUsageRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let mode: OutputMode
    public let command: CLICommandKind
    public let entityCounts: [String: Int]

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        mode: OutputMode,
        command: CLICommandKind,
        entityCounts: [String: Int]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.mode = mode
        self.command = command
        self.entityCounts = entityCounts
    }

    /// Total detections across all types — the list-row summary number.
    public var totalCount: Int {
        entityCounts.values.reduce(0, +)
    }
}

/// Locations + read/append/retention for the shared CLI usage store. Process-agnostic:
/// callers pass the directory their own sandbox resolves (see `directForCLI` /
/// `containerForApp`).
public enum CLIUsageLog {
    /// Shared container id, the directory name under `~/Library/Group Containers`. The Team ID
    /// prefix is required outside the Mac App Store: a Developer ID profile authorizes
    /// `<TeamID>.*`, so an unprefixed id leaves the entitlement unsatisfied. The app then reads the
    /// container without a grant, and macOS 26 asks the user to allow access to other apps' data.
    public static let groupID = "34B4WT759W.group.com.tugboat.clipscrub"
    public static let historyFileName = "cli-history.json"
    public static let configFileName = "cli-config.json"

    /// CLI resolution: builds the `~/Library/Group Containers/<group>/` path directly.
    /// Sandboxed host apps use `containerForApp` instead.
    public static func directForCLI() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/\(groupID)", isDirectory: true)
    }

    /// Sandboxed host-app resolution via `containerURL`. Nil when the shared container is
    /// unavailable — callers degrade to an empty state.
    public static func containerForApp() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    /// The directory an unprefixed group id resolves to. Reading it is the CLI's job, because the
    /// CLI runs outside the sandbox while the app holds no entitlement for that group.
    public static func legacyDirectForCLI() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.tugboat.clipscrub", isDirectory: true)
    }

    /// What one adoption pass did, per file. `failed` is a copy that threw. `alreadyPresent` is a
    /// file this container already had, which is not an error and is not nothing either: the older
    /// copy stays readable only from the old path, so a caller that reports neither leaves the user
    /// looking at rules they did not write.
    public struct ContainerAdoption: Sendable {
        public let failed: [String]
        public let alreadyPresent: [String]
    }

    /// Copy `custom-rules.json`, `cli-history.json` and `cli-config.json` out of the directory an
    /// unprefixed group id resolves to, so rules written before the id changed are still read. The
    /// logging opt-in travels with them, because `cli-config.json` carries it.
    ///
    /// Copies rather than moves and never overwrites, so a failure leaves the only copy of the
    /// user's rules where it was. Callers get both lists back — see `ContainerAdoption`.
    public static func adoptLegacyContainer(
        from legacy: URL = legacyDirectForCLI(),
        to current: URL = directForCLI()
    ) -> ContainerAdoption {
        guard legacy != current else { return ContainerAdoption(failed: [], alreadyPresent: []) }
        let manager = FileManager.default
        var failed: [String] = []
        var alreadyPresent: [String] = []
        for name in [UserRuleStore.fileName, historyFileName, configFileName] {
            let source = legacy.appendingPathComponent(name)
            let destination = current.appendingPathComponent(name)
            guard manager.fileExists(atPath: source.path) else { continue }
            guard !manager.fileExists(atPath: destination.path) else {
                alreadyPresent.append(name)
                continue
            }
            do {
                try manager.createDirectory(at: current, withIntermediateDirectories: true)
                try manager.copyItem(at: source, to: destination)
            } catch {
                failed.append(name)
            }
        }
        return ContainerAdoption(failed: failed, alreadyPresent: alreadyPresent)
    }

    // MARK: Config

    public static func loadConfig(in directory: URL) -> CLILogConfig? {
        let url = directory.appendingPathComponent(configFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(CLILogConfig.self, from: data)
    }

    public static func writeConfig(_ config: CLILogConfig, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(configFileName)
        try encoder().encode(config).write(to: url, options: .atomic)
    }

    // MARK: History

    public static func loadRecords(in directory: URL) -> [CLIUsageRecord] {
        load(in: directory).records
    }

    /// Decoded records + whether the file existed but was undecodable at the top level. Callers that
    /// REWRITE the file (`append`/`applyRetention`) use `corrupt` to move it aside instead of
    /// clobbering bytes this binary can't read (a torn write, or a newer CLI's format under version
    /// skew). Individual undecodable ELEMENTS are skipped, not fatal — one bad record never nukes the
    /// whole batch.
    private static func load(in directory: URL) -> (records: [CLIUsageRecord], corrupt: Bool) {
        let url = directory.appendingPathComponent(historyFileName)
        guard let data = try? Data(contentsOf: url) else { return ([], false) } // absent ⇒ empty, not corrupt
        guard let lenient = try? decoder().decode([FailableRecord].self, from: data) else {
            return ([], true) // present but not a decodable array
        }
        return (lenient.compactMap(\.value), false)
    }

    /// Append one record. Read-modify-write with an atomic replace. CLI runs are short and
    /// infrequent, so the write is not file-coordinated — a rare concurrent run could drop a
    /// record, never corrupt the file or leak data.
    public static func append(_ record: CLIUsageRecord, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let loaded = load(in: directory)
        if loaded.corrupt { preserveCorruptFile(in: directory) }
        try write(loaded.records + [record], in: directory)
    }

    public static func clearRecords(in directory: URL) throws {
        let url = directory.appendingPathComponent(historyFileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Drop records older than `days`; returns the surviving set. Retention is host-owned — the CLI
    /// only appends. Only rewrites when something actually changed (pruned, or a corrupt file moved
    /// aside), so a no-op host read doesn't needlessly race the CLI's append.
    @discardableResult
    public static func applyRetention(days: Int, now: Date, in directory: URL) throws -> [CLIUsageRecord] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let loaded = load(in: directory)
        let kept = loaded.records.filter { $0.timestamp >= cutoff }
        if loaded.corrupt {
            preserveCorruptFile(in: directory)
            try write(kept, in: directory)
        } else if kept.count != loaded.records.count {
            try write(kept, in: directory)
        }
        return kept
    }

    /// Move an undecodable history file aside rather than delete it — the bytes may be recoverable
    /// (e.g. a forward-compat schema change), and it is the user's opt-in log.
    private static func preserveCorruptFile(in directory: URL) {
        let url = directory.appendingPathComponent(historyFileName)
        let backup = directory.appendingPathComponent(historyFileName + ".corrupt")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }

    private static func write(_ records: [CLIUsageRecord], in directory: URL) throws {
        let url = directory.appendingPathComponent(historyFileName)
        try encoder().encode(records).write(to: url, options: .atomic)
    }

    /// Decodes one record, or nil if that element is malformed/unknown — lets the array decode skip
    /// bad elements (torn write, version skew) instead of throwing and failing the whole batch.
    private struct FailableRecord: Decodable {
        let value: CLIUsageRecord?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            value = try? container.decode(CLIUsageRecord.self)
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
