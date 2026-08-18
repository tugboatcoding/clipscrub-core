import Foundation

/// A file the folder scan looked at and did not accept, with the reason to show the user. Nothing is
/// dropped quietly. Somebody who points ClipScrub at a folder of 200 files and gets 197 back needs to
/// be told which 3 were left alone and why.
public struct SkippedFile: Sendable, Equatable {
    public let url: URL
    public let reason: String

    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }
}

/// What one walk of a folder found.
public struct FolderScan: Sendable, Equatable {
    /// Files the redaction path can read, sorted by path so a run is repeatable and progress counts up
    /// in an order the user can follow.
    public let accepted: [URL]
    public let skipped: [SkippedFile]
    /// Non-nil when the walk itself could not run. An empty `accepted` then means "could not look",
    /// which must never reach the user as "nothing here to redact".
    public let error: String?

    public init(accepted: [URL], skipped: [SkippedFile], error: String? = nil) {
        self.accepted = accepted
        self.skipped = skipped
        self.error = error
    }
}

/// Walks a folder and splits what is in it into files the redaction path can read and files it
/// cannot. Pure: it reads the file system and returns URLs. It opens nothing and redacts nothing.
public enum FolderEnumerator {
    /// Walk `root` and every folder under it.
    ///
    /// Hidden files are left alone and app bundles are not walked into, so a `.git` directory or a
    /// `Something.app` sitting in a Downloads folder does not turn into hundreds of entries.
    ///
    /// - Parameter excluding: folders whose contents are not part of the scan. The batch passes its
    ///   own output folder here. That folder lives inside the one being scanned, so without this a
    ///   second run would pick up the first run's redacted files and redact them again.
    public static func scan(_ root: URL, excluding excluded: [URL] = []) -> FolderScan {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isRegularFileKey, .isSymbolicLinkKey]
        // A directory that cannot be read must not read as an empty directory. Each failure is
        // recorded and the walk carries on, so one unreadable subfolder costs its own files and not
        // the whole run.
        let unreadable = Box()
        let rootKey = normalized(root)
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                // A failure on the ROOT is the whole walk failing, and has to be told apart from a
                // subfolder it could not open. `enumerator(at:)` returns non-nil for a folder that is
                // not there, so this handler — not a nil return — is where that arrives.
                if normalized(url) == rootKey {
                    unreadable.rootFailure = error.localizedDescription
                } else {
                    unreadable.append(SkippedFile(url: url,
                                                  reason: "could not be read (\(error.localizedDescription))"))
                }
                return true
            }
        ) else {
            return FolderScan(accepted: [], skipped: [],
                              error: "\(root.lastPathComponent) could not be opened, so nothing was looked at")
        }

        let rootPath = normalized(root) + "/"
        let barriers = excluded.map { normalized($0) + "/" }
        var accepted: [URL] = []
        var skipped: [SkippedFile] = []
        var insideOutputFolder = 0

        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            // `skipsPackageDescendants` stops the walk going INTO a bundle but still hands the bundle
            // itself over, and a folder is never a file to redact. Neither is worth telling the user
            // about, so neither is reported.
            if values?.isDirectory == true || values?.isPackage == true { continue }

            let path = normalized(url)
            if barriers.contains(where: { path.hasPrefix($0) }) {
                insideOutputFolder += 1
                continue
            }

            // A symlink pointing out of the folder would pull content the user never picked into the
            // output, under a name taken from inside the folder. Report it rather than following it.
            if values?.isSymbolicLink == true, !path.hasPrefix(rootPath) {
                skipped.append(SkippedFile(url: url, reason: "a shortcut to a file outside this folder"))
                continue
            }
            if values?.isRegularFile == false { continue }

            // Rich text is turned away here rather than accepted and then failed. Its plain string
            // loses the document's formatting, so a sweep would hand back a .docx that opens wrong —
            // and a file promised in the count and failed at the end reads as a bug.
            if DocumentDecoder.richTextExtensions.contains(url.pathExtension.lowercased()) {
                skipped.append(SkippedFile(
                    url: url,
                    reason: "Word, RTF and HTML keep their formatting only on "
                        + "Capture ▸ Redact Document to File…"))
            } else if DocumentDecoder.supports(url) {
                accepted.append(url)
            } else {
                skipped.append(SkippedFile(url: url, reason: reasonForUnsupported(url)))
            }
        }

        // One line rather than one per file: a second run of a thousand-file folder would otherwise
        // report a thousand skips for its own output, and bury the ones that matter.
        if let outputFolder = excluded.first, insideOutputFolder > 0 {
            skipped.append(SkippedFile(
                url: outputFolder,
                reason: "\(insideOutputFolder) file\(insideOutputFolder == 1 ? "" : "s") already in this "
                    + "folder were not looked at"))
        }
        skipped.append(contentsOf: unreadable.contents)

        return FolderScan(
            accepted: accepted.sorted { normalized($0) < normalized($1) },
            skipped: skipped.sorted { normalized($0.url) < normalized($1.url) },
            error: unreadable.rootFailure.map {
                "\(root.lastPathComponent) could not be read (\($0)), so nothing was looked at"
            })
    }

    /// Compare resolved paths. `/var` is a symlink to `/private/var` on macOS, so the panel can hand
    /// back one spelling while the walker produces the other, and a plain string comparison then puts
    /// the output folder back into the scan.
    private static func normalized(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func reasonForUnsupported(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return "no file extension, so ClipScrub cannot tell what it holds" }
        return "ClipScrub does not read .\(ext) files"
    }

    /// Collects what the enumerator's error handler reports. A reference type because that handler is
    /// held by the enumerator rather than called inline.
    private final class Box {
        private(set) var contents: [SkippedFile] = []
        /// Why the folder being swept could not itself be read.
        var rootFailure: String?
        func append(_ file: SkippedFile) { contents.append(file) }
    }
}
