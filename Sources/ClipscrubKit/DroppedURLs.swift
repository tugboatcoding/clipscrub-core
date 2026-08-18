import Foundation

/// Where a set of dropped or picked URLs goes.
public struct DroppedURLRoute: Sendable, Equatable {
    public let videos: [URL]
    public let folders: [URL]
    /// Loose files to review one at a time, already cut to the limit.
    public let files: [URL]
    /// Loose files set aside because a folder was in the same set. Never zero silently — the caller
    /// has to say so.
    public let looseIgnored: Int
    /// How many loose files there were, when that was more than the limit. Nil when nothing was cut.
    public let foundCount: Int?

    public init(videos: [URL], folders: [URL], files: [URL], looseIgnored: Int, foundCount: Int?) {
        self.videos = videos
        self.folders = folders
        self.files = files
        self.looseIgnored = looseIgnored
        self.foundCount = foundCount
    }
}

/// Splits an arriving set of URLs into the paths that handle them.
///
/// Pure, and the classifiers are passed in, so the rules can be tested without a file system: what
/// counts as a clip and what counts as a folder are both questions about bytes on disk.
public enum DroppedURLs {
    /// - Parameters:
    ///   - limit: the most loose files one review batch takes.
    ///   - isVideo: clips leave first. They have no image representation, so a clip left in the batch
    ///     falls through every branch below having produced nothing and said nothing.
    ///   - isFolder: a package (`.app`, `.rtfd`) is a directory to the file system and one document to
    ///     the user, so the caller's classifier decides.
    public static func route(_ urls: [URL], limit: Int,
                             isVideo: (URL) -> Bool,
                             isFolder: (URL) -> Bool) -> DroppedURLRoute {
        var videos: [URL] = []
        var folders: [URL] = []
        var loose: [URL] = []
        for url in urls {
            if isVideo(url) {
                videos.append(url)
            } else if isFolder(url) {
                folders.append(url)
            } else {
                loose.append(url)
            }
        }

        // A folder wins the loose files in the same set. Both paths drive one progress row, so running
        // them together leaves whichever finished first hiding the other — including the folder run's
        // Cancel button. The count comes back so the caller can say what it set aside.
        if !folders.isEmpty {
            return DroppedURLRoute(videos: videos, folders: folders, files: [],
                                   looseIgnored: loose.count, foundCount: nil)
        }

        // Cut BEFORE the caller decodes anything. This used to be a `prefix` after every file had
        // already been decoded, so 500 dropped screenshots were read into memory in full to keep 50.
        guard loose.count > limit else {
            return DroppedURLRoute(videos: videos, folders: [], files: loose,
                                   looseIgnored: 0, foundCount: nil)
        }
        return DroppedURLRoute(videos: videos, folders: [], files: Array(loose.prefix(limit)),
                               looseIgnored: 0, foundCount: loose.count)
    }
}
