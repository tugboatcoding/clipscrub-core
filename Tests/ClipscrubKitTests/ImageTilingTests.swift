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

    /// Tiles overlap, so the same line can be read twice at slightly different places. The word
    /// boxes can only come from the read whose text won, which leaves them silent about ink the
    /// other read saw — and a box drawn from them alone leaves that copy of the identifier showing.
    /// A merge where the loser reaches past the winner's words therefore gives the word boxes up.
    func testAMergeThatMovesTheWordsAlongTheLineDropsTheWordGeometry() {
        let wide = OCRObservation(
            text: "Reviewed MRN 88213 signed",
            box: CGRect(x: 0, y: 100, width: 300, height: 20),
            wordBoxes: [.init(range: 9..<18, box: CGRect(x: 85, y: 100, width: 115, height: 20))]
        )
        // The same MRN, read by the neighbouring tile a little further right.
        let shifted = OCRObservation(
            text: "MRN 88213",
            box: CGRect(x: 250, y: 100, width: 60, height: 20),
            wordBoxes: [.init(range: 0..<9, box: CGRect(x: 250, y: 100, width: 60, height: 20))]
        )

        let merged = ImageTiling.dedupedObservations([wide, shifted])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].box.maxX, 310, accuracy: 0.5)
        XCTAssertTrue(merged[0].wordBoxes.isEmpty,
                      "word boxes reach 300 and the merged line reaches 310 — keeping them leaves ink at 300-310 uncovered")
    }

    /// The other half of that rule, and the case that actually happens. Two tiles read the same line
    /// a couple of pixels apart vertically and agree on where its words are. Measured on a 1200x2600
    /// capture: 35 lines read twice, up to 3px apart, agreeing horizontally to about 1e-5 px. The
    /// geometry has to survive that or a tall capture is redacted a whole line at a time.
    func testTheSameLineReadTwiceAFewPixelsApartKeepsItsWordGeometry() {
        let words: [OCRObservation.WordBox] = [
            .init(range: 0..<3, box: CGRect(x: 40, y: 100, width: 50, height: 21)),
            .init(range: 4..<9, box: CGRect(x: 95, y: 100, width: 90, height: 21)),
        ]
        let first = OCRObservation(text: "MRN 88213", box: CGRect(x: 40, y: 100, width: 145, height: 21),
                                   wordBoxes: words)
        let secondTile = OCRObservation(text: "MRN 88213", box: CGRect(x: 40, y: 103, width: 145, height: 21),
                                        wordBoxes: words.map {
                                            .init(range: $0.range, box: $0.box.offsetBy(dx: 0, dy: 3))
                                        })

        let merged = ImageTiling.dedupedObservations([first, secondTile])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].wordBoxes.count, 2, "a few pixels of vertical drift is not a reason to give up")
        // Grown to the merged height, so the lower read's ink is covered too.
        XCTAssertEqual(merged[0].box.height, 24, accuracy: 0.5)
        for word in merged[0].wordBoxes {
            XCTAssertEqual(word.box.minY, merged[0].box.minY, accuracy: 0.01)
            XCTAssertEqual(word.box.height, merged[0].box.height, accuracy: 0.01)
        }
    }

    /// Vision reports a line's box with non-integral edges, and a union of two of them is not
    /// bit-equal to either — `union` recomputes width as maxX - minX. So an exact box comparison
    /// dropped the geometry of every repeated line. Keep the fixture's edges non-integral or it
    /// stops pinning anything.
    func testTwoIdenticalNonIntegralReadsKeepTheirGeometry() {
        let words: [OCRObservation.WordBox] = [
            .init(range: 0..<3, box: CGRect(x: 39.9999917, y: 100, width: 50.000016, height: 21)),
        ]
        let box = CGRect(x: 39.9999917, y: 100, width: 50.000016, height: 21)
        let read = OCRObservation(text: "MRN", box: box, wordBoxes: words)
        let again = OCRObservation(text: "MRN", box: box, wordBoxes: words)

        XCTAssertNotEqual(box.union(box), box, "the fixture must not have bit-equal edges")
        let merged = ImageTiling.dedupedObservations([read, again])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].wordBoxes.count, 1)
    }

    /// The losing read reaches past the winner's last word. Growing only the outermost words would
    /// cover this, but growing them cannot cover the gap case below, so neither is grown and the
    /// whole line goes instead.
    func testALoserReachingPastTheLastWordDropsTheGeometry() {
        let line = OCRObservation(
            text: "MRN 88213 Ward 4B",
            box: CGRect(x: 40, y: 100, width: 540, height: 21),
            wordBoxes: [
                .init(range: 0..<3, box: CGRect(x: 40, y: 100, width: 50, height: 21)),
                .init(range: 4..<9, box: CGRect(x: 95, y: 100, width: 100, height: 21)),
                .init(range: 10..<14, box: CGRect(x: 480, y: 100, width: 50, height: 21)),
                .init(range: 15..<17, box: CGRect(x: 535, y: 100, width: 45, height: 21)),
            ]
        )
        // Same text, read 20px further right — inside a line height, which used to be allowed.
        let shifted = OCRObservation(text: "MRN 88213 Ward 4B",
                                     box: CGRect(x: 60, y: 100, width: 540, height: 21))

        let merged = ImageTiling.dedupedObservations([line, shifted])
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].wordBoxes.isEmpty,
                      "the loser reaches to x=600 and the words stop at 580 — 20px of it would show")
    }

    /// A narrow cell sitting in the gap between two columns of the wide line around it. The merge
    /// grows the box by 2px vertically, exactly like the harmless case, so nothing about the merged
    /// box tells them apart. The loser's own position does.
    func testALoserInTheGapBetweenTwoWordsDropsTheGeometry() {
        let header = OCRObservation(
            text: "Patient record - MRN 88213 - exported",
            box: CGRect(x: 0, y: 100, width: 720, height: 24),
            wordBoxes: [
                .init(range: 0..<7, box: CGRect(x: 0, y: 100, width: 90, height: 24)),
                .init(range: 8..<14, box: CGRect(x: 96, y: 100, width: 90, height: 24)),
                // The column gap runs from 186 to 500.
                .init(range: 17..<26, box: CGRect(x: 500, y: 100, width: 120, height: 24)),
                .init(range: 29..<37, box: CGRect(x: 625, y: 100, width: 95, height: 24)),
            ]
        )
        let badge = OCRObservation(text: "MRN 88213", box: CGRect(x: 300, y: 108, width: 90, height: 18))

        let merged = ImageTiling.dedupedObservations([header, badge])
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].wordBoxes.isEmpty,
                      "the badge sits at x=300-390, in the gap between words — all 90px of it would show")
    }

    /// The line the tiling comment describes: a strip edge cuts a line, so the read above it is
    /// short and the one below is whole. The LOWER read wins, and its words have to be grown up to
    /// the merged top or the upper read's ink is left showing.
    func testWhenTheLowerReadWinsItsWordsGrowUpToCoverTheUpperOne() {
        let clipped = OCRObservation(text: "MRN 88", box: CGRect(x: 40, y: 100, width: 145, height: 8))
        let whole = OCRObservation(
            text: "MRN 88213",
            box: CGRect(x: 40, y: 103, width: 145, height: 21),
            wordBoxes: [
                .init(range: 0..<3, box: CGRect(x: 40, y: 103, width: 50, height: 21)),
                .init(range: 4..<9, box: CGRect(x: 95, y: 103, width: 90, height: 21)),
            ]
        )

        let merged = ImageTiling.dedupedObservations([clipped, whole])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, "MRN 88213", "the whole read wins")
        XCTAssertEqual(merged[0].wordBoxes.count, 2)
        for word in merged[0].wordBoxes {
            XCTAssertEqual(word.box.minY, 100, accuracy: 0.01, "grown up to the clipped read's top")
            XCTAssertEqual(word.box.maxY, 124, accuracy: 0.01)
        }
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
