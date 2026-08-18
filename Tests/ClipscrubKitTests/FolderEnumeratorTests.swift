import XCTest
@testable import ClipscrubKit

/// A temporary folder to build a tree in, shared by the two suites below.
class FolderEnumeratorTestCase: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FolderEnumeratorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    @discardableResult
    func write(_ path: String, bytes: String = "x") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent).sorted() }
}

/// What the walk accepts and what it reports.
final class FolderEnumeratorTests: FolderEnumeratorTestCase {
    func testWalksSubfoldersAndKeepsSupportedFiles() throws {
        try write("top.png")
        try write("nested/deep/notes.txt")
        try write("nested/scan.pdf")

        let scan = FolderEnumerator.scan(root)

        XCTAssertEqual(names(scan.accepted), ["notes.txt", "scan.pdf", "top.png"])
        XCTAssertTrue(scan.skipped.isEmpty)
        XCTAssertNil(scan.error)
    }

    func testHiddenFilesAndPackagesAreNeitherAcceptedNorReported() throws {
        try write("keep.png")
        try write(".hidden.png")
        try write(".git/objects/blob.png")
        // A bundle is a directory to the file system and one thing to the user. The walk must neither
        // descend into it nor hand back the bundle itself.
        try write("Some.app/Contents/Resources/icon.png")

        let scan = FolderEnumerator.scan(root)

        XCTAssertEqual(names(scan.accepted), ["keep.png"])
        XCTAssertTrue(scan.skipped.isEmpty, "a hidden file or a bundle is not a file the user chose")
    }

    func testUnsupportedFilesAreReportedWithAReason() throws {
        try write("shot.png")
        try write("build.swift")
        try write("README")

        let scan = FolderEnumerator.scan(root)

        XCTAssertEqual(names(scan.accepted), ["shot.png"])
        XCTAssertEqual(names(scan.skipped.map(\.url)), ["README", "build.swift"])
        XCTAssertEqual(scan.skipped.first { $0.url.lastPathComponent == "build.swift" }?.reason,
                       "ClipScrub does not read .swift files")
        XCTAssertEqual(scan.skipped.first { $0.url.lastPathComponent == "README" }?.reason,
                       "no file extension, so ClipScrub cannot tell what it holds")
    }

    /// Rich text is reported by the walk rather than accepted and failed later. Its plain string loses
    /// the document's formatting, so a sweep cannot write a .docx back out — and a file counted in
    /// "Redact N Files" that then lands in the failure list reads as a bug.
    func testRichTextIsReportedByTheWalkRatherThanAccepted() throws {
        try write("shot.png")
        try write("letter.docx")
        try write("memo.rtf")

        let scan = FolderEnumerator.scan(root)

        XCTAssertEqual(names(scan.accepted), ["shot.png"])
        XCTAssertEqual(names(scan.skipped.map(\.url)), ["letter.docx", "memo.rtf"])
        XCTAssertTrue(scan.skipped.allSatisfy { $0.reason.contains("Redact Document to File") })
    }

    /// A shortcut pointing out of the folder would pull in content the user never picked, and write it
    /// out under a name taken from inside the folder.
    func testASymlinkOutOfTheFolderIsReportedNotFollowed() throws {
        try write("inside.png")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).png")
        try Data("x".utf8).write(to: outside)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.png"),
                                                   withDestinationURL: outside)

        let scan = FolderEnumerator.scan(root)

        XCTAssertEqual(names(scan.accepted), ["inside.png"])
        XCTAssertEqual(scan.skipped.first { $0.url.lastPathComponent == "link.png" }?.reason,
                       "a shortcut to a file outside this folder")
    }
}

/// The edges: the excluded output folder, an empty folder, a folder that cannot be walked at all.
final class FolderEnumeratorBoundaryTests: FolderEnumeratorTestCase {
    func testExcludedFolderIsNotScannedAndIsSaidOnce() throws {
        try write("shot.png")
        try write("Redacted/shot.png")
        try write("Redacted/other.png")

        let scan = FolderEnumerator.scan(root, excluding: [root.appendingPathComponent("Redacted", isDirectory: true)])

        XCTAssertEqual(names(scan.accepted), ["shot.png"], "a second run must not redact the first run's output")
        // One line rather than one per file: a thousand-file re-run would otherwise report a thousand
        // skips for its own output and bury the ones that matter.
        XCTAssertEqual(scan.skipped.count, 1)
        XCTAssertEqual(scan.skipped.first?.reason, "2 files already in this folder were not looked at")
    }

    func testEmptyFolderIsEmptyAndNotAnError() {
        let scan = FolderEnumerator.scan(root)

        XCTAssertTrue(scan.accepted.isEmpty)
        XCTAssertTrue(scan.skipped.isEmpty)
        XCTAssertNil(scan.error, "an empty folder is a fact, not a failure")
    }

    /// A walk that could not run must never look like a folder with nothing in it. One reads as
    /// "redacted 0 files", the other as "could not look" — and only one of them is safe to believe.
    func testAFolderThatCannotBeWalkedReportsAnError() {
        let missing = root.appendingPathComponent("does-not-exist", isDirectory: true)

        let scan = FolderEnumerator.scan(missing)

        XCTAssertTrue(scan.accepted.isEmpty)
        XCTAssertNotNil(scan.error)
    }
}
