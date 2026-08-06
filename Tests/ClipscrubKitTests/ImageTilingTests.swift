import CoreGraphics
import XCTest
@testable import ClipscrubKit

final class ImageTilingTests: XCTestCase {
    func testStartsCoverTheWholeAxisWithTheRequestedOverlap() {
        XCTAssertEqual(ImageTiling.starts(total: 1200, size: 2048, overlap: 384), [0])
        XCTAssertEqual(ImageTiling.starts(total: 2048, size: 2048, overlap: 384), [0])

        for total in [2049, 3000, 4096, 15360, 40000] {
            let starts = ImageTiling.starts(total: total, size: 2048, overlap: 384)
            XCTAssertEqual(starts.first, 0, "total \(total)")
            XCTAssertEqual(starts.last, total - 2048, "total \(total) must end flush with the far edge")
            XCTAssertTrue(zip(starts, starts.dropFirst()).allSatisfy { $1 - $0 <= 2048 - 384 }, "total \(total)")
        }
        // Overlap counts for at most half a tile (1024 here), so an extreme request cannot become a
        // pixel walk — 13312 to cover in 1024 steps is 14 tiles, not 13313.
        XCTAssertEqual(ImageTiling.starts(total: 15360, size: 2048, overlap: 2048).count, 14)
    }

    func testTilesCoverEveryCornerOfTheSource() throws {
        let image = solidImage(width: 1600, height: 5000)
        for tiles in [try ImageTiling.strips(of: image), try ImageTiling.grid(of: image)] {
            let covered = tiles.map { tile in
                CGRect(x: tile.origin.x, y: tile.origin.y,
                       width: CGFloat(tile.image.cgImage.width), height: CGFloat(tile.image.cgImage.height))
            }
            XCTAssertTrue(covered.allSatisfy { $0.maxX <= 1600 && $0.maxY <= 5000 })
            for corner in [CGPoint(x: 1, y: 1), CGPoint(x: 1599, y: 1),
                           CGPoint(x: 1, y: 4999), CGPoint(x: 1599, y: 4999)] {
                XCTAssertTrue(covered.contains { $0.contains(corner) }, "\(corner) would go unread")
            }
        }
    }

    func testCaptureMuchWiderThanTallIsCutIntoColumns() throws {
        // The same failure as a tall capture, sideways — one whole-image read of this returns nothing.
        let wide = try ImageTiling.strips(of: solidImage(width: 15200, height: 1200))
        XCTAssertTrue(wide.contains { $0.origin.x > 0 }, "expected columns, not one full-width strip")

        // A normal screen grab keeps its full width. Cutting it would split lines for nothing.
        let screen = try ImageTiling.strips(of: solidImage(width: 5120, height: 2880))
        XCTAssertTrue(screen.allSatisfy { $0.origin.x == 0 && $0.image.cgImage.width == 5120 })
    }

    func testTileMapsItsOwnRectBackIntoSourcePixels() throws {
        let tiles = try ImageTiling.strips(of: solidImage(width: 1600, height: 5000))
        let second = try XCTUnwrap(tiles.dropFirst().first)
        let inTile = CGRect(x: 40, y: 10, width: 100, height: 20)

        XCTAssertTrue(second.origin.y > 0, "the second strip starts below the top of the source")
        XCTAssertEqual(second.inSource(inTile), inTile.offsetBy(dx: 0, dy: second.origin.y))
    }

    func testRepeatedLineKeepsTheLongerReadingAndCoversBothBoxes() {
        // A line cut by a strip edge reads short in one strip and whole in its neighbour.
        let clipped = OCRObservation(text: "Sarah Chen Jul 1", box: CGRect(x: 40, y: 94, width: 300, height: 14))
        let whole = OCRObservation(text: "Sarah Chen Jul 12, 2026", box: CGRect(x: 40, y: 98, width: 420, height: 20))
        let deduped = ImageTiling.dedupedObservations([clipped, whole])

        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped.first?.text, "Sarah Chen Jul 12, 2026")
        // Box covers both readings (94…118), so the redaction cannot land short of what was read.
        XCTAssertEqual(deduped.first?.box, CGRect(x: 40, y: 94, width: 420, height: 24))
    }

    func testDifferentReadingsInTheSameSpaceBothSurvive() {
        // A short cell sits inside the wide line around it. Collapsing on position alone would
        // delete "MRN 88213" before any detector saw it.
        let row = OCRObservation(text: "Reviewed and signed off", box: CGRect(x: 0, y: 100, width: 600, height: 20))
        let cell = OCRObservation(text: "MRN 88213", box: CGRect(x: 200, y: 102, width: 90, height: 16))

        XCTAssertEqual(ImageTiling.dedupedObservations([row, cell]).count, 2)
    }

    func testRepeatedRegionGrowsTheKeptBoxInsteadOfDroppingPixels() {
        let whole = region(CGRect(x: 296, y: 4261, width: 122, height: 122))
        let sliver = region(CGRect(x: 323, y: 4319, width: 66, height: 67)) // same face, edge of the next tile
        let elsewhere = region(CGRect(x: 40, y: 200, width: 80, height: 80))
        let deduped = ImageTiling.dedupedRegions([sliver, whole, elsewhere])

        XCTAssertEqual(deduped.count, 2)
        // The sliver reaches 3 px below the box that swallowed it — those pixels stay covered.
        XCTAssertTrue(deduped.contains { boxOf($0) == CGRect(x: 296, y: 4261, width: 122, height: 125) })
        XCTAssertTrue(deduped.contains { boxOf($0) == CGRect(x: 40, y: 200, width: 80, height: 80) })
    }

    private func solidImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func region(_ box: CGRect) -> DetectedEntity {
        DetectedEntity(type: .face, value: "face", confidence: 0.9, source: .face, locus: .region(box))
    }

    private func boxOf(_ entity: DetectedEntity) -> CGRect? {
        guard case let .region(box) = entity.locus else { return nil }
        return box
    }
}
