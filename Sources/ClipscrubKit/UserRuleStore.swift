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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(StoredFile(version: currentVersion, rules: rules.map(FailableRule.init)))
            .write(to: url, options: .atomic)
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
