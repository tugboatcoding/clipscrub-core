import Foundation

/// Reads and writes custom rules in a caller-provided directory.
public enum UserRuleStore {
    public static let fileName = "custom-rules.json"

    /// Bumped when the on-disk shape changes in a way an older build cannot read. An unknown version
    /// is treated as unreadable rather than guessed at — see `load`.
    public static let currentVersion = 1

    /// The CLI's shared rule directory.
    public static func directForCLI() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/\(CLIUsageLog.groupID)", isDirectory: true)
    }

    // MARK: Read and write

    /// Rules on disk, or an empty list when there are none.
    ///
    /// An absent file means the user has not written a rule yet, which is not an error. A file that
    /// cannot be decoded at the top level is a different thing and is handled by `save` — the bytes
    /// are moved aside rather than overwritten, because they may be recoverable and they are the
    /// only copy of work the user typed.
    public static func load(in directory: URL) -> [UserRule] {
        loadDetailed(in: directory).rules
    }

    /// Rules plus whether the file was present and undecodable, which only rewriting callers need.
    public static func loadDetailed(in directory: URL) -> (rules: [UserRule], corrupt: Bool) {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return ([], false) }
        guard let file = try? JSONDecoder().decode(StoredFile.self, from: data) else { return ([], true) }
        // A file written by a newer build may use fields this one would drop on the next save, so it
        // is left alone rather than half-read. Same reasoning as an undecodable file.
        guard file.version <= currentVersion else { return ([], true) }
        return (file.rules.compactMap(\.value), false)
    }

    public static func save(_ rules: [UserRule], in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if loadDetailed(in: directory).corrupt { preserveCorruptFile(in: directory) }
        let url = directory.appendingPathComponent(fileName)
        try encode(rules).write(to: url, options: .atomic)
    }

    // MARK: Import and export

    /// The same bytes `save` would write, handed back instead of written to a fixed path — this is
    /// what backs the Settings ▸ Rules Export button. Uses the same `StoredFile` envelope, so the
    /// result is itself a valid `custom-rules.json` and can be dropped straight back in via `decode`
    /// or read from disk by `load`.
    ///
    /// Throws rather than swallowing a failure into empty `Data` — this feeds a file write on a
    /// redaction-adjacent path, and a caller that got an empty file back would report a successful
    /// export that actually threw away every rule.
    public static func exportData(_ rules: [UserRule]) throws -> Data {
        try encode(rules)
    }

    /// Rules decoded from a `custom-rules.json`-shaped payload, and how many entries the file
    /// actually held — the gap between the two is what an importer reports as "imported N of M",
    /// same doctrine as `fileUnreadable` on `load`: a bad entry is dropped, not hidden.
    ///
    /// Goes through the same version gate as `loadDetailed`: a file from a newer build throws
    /// rather than being half-read, because it may use fields this build would drop on the next
    /// save.
    ///
    /// Also refuses a file claiming more than `maxImportedRuleCount` entries. Nothing this app
    /// writes gets anywhere near that many — this is a floor against a hand-crafted or corrupted
    /// file turning "decode a shared rules file" into building an enormous in-memory array and then
    /// compiling every one of its patterns.
    public static func decodeDetailed(_ data: Data) throws -> (rules: [UserRule], total: Int) {
        let file = try JSONDecoder().decode(StoredFile.self, from: data)
        guard file.version <= currentVersion else { throw ImportError.futureVersion(file.version) }
        guard file.rules.count <= maxImportedRuleCount else { throw ImportError.tooManyRules(file.rules.count) }
        return (file.rules.compactMap(\.value), file.rules.count)
    }

    /// Well past anything a person would hand-write or a preset would ship (the largest bundled
    /// preset here is 8 rules) — see `decodeDetailed`.
    public static let maxImportedRuleCount = 2_000

    /// Rules decoded from a `custom-rules.json`-shaped payload. Entries that don't decode are
    /// dropped rather than failing the whole import — see `decodeDetailed` for how many were.
    public static func decode(_ data: Data) throws -> [UserRule] {
        try decodeDetailed(data).rules
    }

    /// Why an import was refused outright, as opposed to landing with some rules dropped.
    public enum ImportError: Error, Sendable, Equatable {
        /// The file's format version is newer than this build understands.
        case futureVersion(Int)
        /// The file claims more entries than `maxImportedRuleCount` allows.
        case tooManyRules(Int)
    }

    private static func encode(_ rules: [UserRule]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(StoredFile(version: currentVersion, rules: rules.map(FailableRule.init)))
    }

    /// Move an unreadable file aside instead of deleting it. The bytes may be recoverable, and they
    /// are rules the user wrote by hand — losing them to a decode error nobody saw is worse than
    /// leaving a file on disk.
    private static func preserveCorruptFile(in directory: URL) {
        let url = directory.appendingPathComponent(fileName)
        let backup = directory.appendingPathComponent(fileName + ".corrupt")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }

    private struct StoredFile: Codable {
        let version: Int
        let rules: [FailableRule]
    }

    /// Decodes one rule, or nil when that entry is malformed. Lets the array skip a bad entry instead
    /// of throwing and losing every other rule in the file to it.
    private struct FailableRule: Codable {
        let value: UserRule?

        init(_ rule: UserRule) {
            value = rule
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            value = try? container.decode(UserRule.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
    }
}

extension UserRuleStore.ImportError: LocalizedError {
    /// Written out because this string is what the person reads in the import failure alert — the
    /// default for an enum is its own case syntax, which names nothing they can act on.
    public var errorDescription: String? {
        switch self {
        case .futureVersion(let version):
            "This file was saved by a newer version of ClipScrub (format \(version)) and can't be read here."
        case .tooManyRules(let count):
            "This file lists \(count) rules, well past what ClipScrub imports at once (\(UserRuleStore.maxImportedRuleCount)). It's probably not a rules file."
        }
    }
}
