import XCTest
@testable import ClipscrubKit

/// The rules a set of dropped or picked URLs goes through, tested without a file system. Both the drop
/// handler and the file picker call this, so a rule broken here breaks both.
final class DroppedURLsTests: XCTestCase {
    private func urls(_ names: [String]) -> [URL] {
        names.map { URL(fileURLWithPath: "/tmp/\($0)") }
    }

    private func route(_ names: [String], limit: Int = 50,
                       videos: Set<String> = [], folders: Set<String> = []) -> DroppedURLRoute {
        DroppedURLs.route(urls(names), limit: limit,
                          isVideo: { videos.contains($0.lastPathComponent) },
                          isFolder: { folders.contains($0.lastPathComponent) })
    }

    /// The cap used to be a `prefix` applied AFTER every file had been decoded, so 500 dropped
    /// screenshots were read into memory in full to keep 50.
    func testAnOversizedBatchIsCutAndTheCountFoundSurvivesForTheNotice() {
        let names = (0..<500).map { "shot-\($0).png" }

        let result = route(names)

        XCTAssertEqual(result.files.count, 50)
        XCTAssertEqual(result.files.first?.lastPathComponent, "shot-0.png", "the cut keeps the front, in order")
        XCTAssertEqual(result.foundCount, 500, "the notice says the first 50 of 500, so 500 has to survive")
    }

    func testABatchWithinTheCapIsPassedThroughWithNothingAnnounced() {
        let result = route(["a.png", "b.png"])

        XCTAssertEqual(result.files.count, 2)
        XCTAssertNil(result.foundCount)
        XCTAssertEqual(result.looseIgnored, 0)
    }

    /// Both paths drive one progress row, so running them together hides one behind the other —
    /// including the folder run's Cancel button.
    func testAFolderWinsTheSetAndTheLooseFilesAreCounted() {
        let result = route(["shots", "a.png", "b.png"], folders: ["shots"])

        XCTAssertEqual(result.folders.map(\.lastPathComponent), ["shots"])
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertEqual(result.looseIgnored, 2, "files set aside are counted, never dropped in silence")
    }

    /// A clip has no image representation, so one left in the batch falls through every branch having
    /// produced nothing and said nothing.
    func testClipsLeaveFirstAndTheRestStillGoThrough() {
        let result = route(["clip.mp4", "a.png"], videos: ["clip.mp4"])

        XCTAssertEqual(result.videos.map(\.lastPathComponent), ["clip.mp4"])
        XCTAssertEqual(result.files.map(\.lastPathComponent), ["a.png"])
    }

    func testAFolderAlsoWinsOverClipsBeingSeparatelyReported() {
        let result = route(["shots", "clip.mp4"], videos: ["clip.mp4"], folders: ["shots"])

        XCTAssertEqual(result.videos.count, 1, "a clip still opens — it does not share the progress row")
        XCTAssertEqual(result.folders.count, 1)
    }
}
