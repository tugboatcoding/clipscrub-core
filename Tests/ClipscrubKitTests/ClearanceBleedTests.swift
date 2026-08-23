import CoreGraphics
import CoreText
import PDFKit
import XCTest
@testable import ClipscrubKit

/// The margin `PDFTextLayer` grows a redaction box by before it tests a character against it.
///
/// Two directions to get wrong. Too little and a covered value is written back as searchable text.
/// Too much and the box reaches the line beneath it and deletes words the page still shows. The
/// first test is the fidelity half, the other two are the safety half.
final class ClearanceBleedTests: XCTestCase {
    private let line1 = "26 SECRETNAME usage calls to ACME totalling:"
    private let line2 = "$2.37. Input tokens: 52, Output tokens: 34674"

    /// Two lines of Helvetica at receipt spacing, which is where the lines sit close enough to
    /// reach each other.
    private let leading: CGFloat = 13.4

    private func makePDF() -> Data {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data)!
        var box = CGRect(x: 0, y: 0, width: 420, height: 80)
        let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(box)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for (i, line) in [line1, line2].enumerated() {
            let attr = NSAttributedString(string: line, attributes: [.font: font])
            ctx.textPosition = CGPoint(x: 10, y: 50 - CGFloat(i) * leading)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        }
        ctx.endPDFPage(); ctx.closePDF()
        return data as Data
    }

    private func makePDFURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipscrub-clearance-\(UUID().uuidString).pdf")
        try makePDF().write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Page points, bottom-left origin -> raster pixels, top-left origin. Region loci live in the
    /// second frame, character boxes in the first.
    private func raster(_ rect: CGRect, pageHeight: CGFloat, scale: CGFloat) -> CGRect {
        CGRect(x: rect.minX * scale, y: (pageHeight - rect.maxY) * scale,
               width: rect.width * scale, height: rect.height * scale)
    }

    /// The raster rect covering exactly `value` — the frame a region locus uses.
    private func cover(_ value: String, on page: PDFPage, scale: CGFloat,
                       lineHeight: CGFloat) throws -> (CGRect, CGSize) {
        let full = page.string ?? ""
        let r = (full as NSString).range(of: value)
        XCTAssertNotEqual(r.location, NSNotFound, "\(value) is not on the page")
        var union = CGRect.null
        for i in r.location..<(r.location + r.length) { union = union.union(page.characterBounds(at: i)) }
        let pageBox = page.bounds(for: .mediaBox)
        // ClipScrub's boxes are drawn around the LINE, not tight to the glyphs — measured at 13pt
        // on a 6.7pt font in the real receipt. A tight box is what made the first version of this
        // test pass while the shipping app bled.
        union = union.insetBy(dx: 0, dy: -(lineHeight - union.height) / 2)
        return (raster(union, pageHeight: pageBox.height, scale: scale),
                CGSize(width: pageBox.width * scale, height: pageBox.height * scale))
    }

    private func kept(_ text: PDFPageText, covering rect: CGRect, rasterSize: CGSize) -> String {
        let safe = PDFTextLayer.sanitized(from: text, redactions: [rect], rasterSize: rasterSize)
        return (safe?.characters.map { String($0.character) }.joined() ?? "")
            .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - Fidelity

    /// The reproduction. A box drawn around line 1 used to take the top of line 2 with it, so the
    /// export read `$ ns: 52, Outp 55,` where the page plainly showed the amount and the counts.
    func testCoveringOneLineDoesNotEatTheLineBelow() throws {
        for (scale, lineHeight) in [(CGFloat(1), CGFloat(13)), (2, 13), (1, 7), (2, 7)] {
            let doc = try XCTUnwrap(PDFDocument(data: makePDF()))
            let page = try XCTUnwrap(doc.page(at: 0))
            let text = try XCTUnwrap(PDFPageText.extract(from: page))
            let (rect, rasterSize) = try cover("SECRETNAME", on: page, scale: scale,
                                               lineHeight: lineHeight)
            let keptText = kept(text, covering: rect, rasterSize: rasterSize)

            XCTAssertFalse(keptText.contains("SECRETNAME"), "the covered value survived")
            XCTAssertTrue(keptText.contains(line2),
                          "scale \(Int(scale))x, box \(Int(lineHeight))pt tall: line 2 lost text.\n"
                          + "  want line 2: \(line2)\n  kept:        \(keptText)")
        }
    }

    // MARK: - Safety

    /// The counter-test for dropping the vertical margin. A box that reaches a character's box at
    /// all still takes that character, however little of it is overlapped — a quarter of a point is
    /// a third of a raster pixel at 2x. Widen the gate's vertical inset in either direction and
    /// this reds.
    func testABoxThatBarelyReachesALineStillTakesIt() throws {
        for scale in [CGFloat(1), 2] {
            for overlap in [CGFloat(0.25), 0.5, 1, 2] {
                let doc = try XCTUnwrap(PDFDocument(data: makePDF()))
                let page = try XCTUnwrap(doc.page(at: 0))
                let text = try XCTUnwrap(PDFPageText.extract(from: page))
                let pageBox = page.bounds(for: .mediaBox)

                // A band sitting above line 2 and dipping `overlap` points into its character boxes.
                let line2Box = try box(of: "Output tokens", in: text)
                let band = CGRect(x: line2Box.minX, y: line2Box.maxY - overlap,
                                  width: line2Box.width, height: 5)
                let keptText = kept(text, covering: raster(band, pageHeight: pageBox.height,
                                                           scale: scale),
                                    rasterSize: CGSize(width: pageBox.width * scale,
                                                       height: pageBox.height * scale))

                XCTAssertFalse(
                    keptText.contains("Output tokens"),
                    "scale \(Int(scale))x: a box overlapping the line by \(overlap)pt left it "
                    + "readable.\n  kept: \(keptText)"
                )
            }
        }
    }

    /// The gate is now narrower vertically than the black the app paints, so a character can be
    /// kept while the paint clips the edge of its box. This measures what that costs in INK, which
    /// is the thing a reader loses — a box is a full line tall and mostly leading, so overlapping
    /// one says little.
    ///
    /// The box here stops one raster pixel above the line below it, which is the worst case: the
    /// 2px bleed reaches that line and the gate does not. Ink is read out of the source pixels and
    /// the painted rectangle out of the difference between the two rasters, so neither side of the
    /// comparison is a constant this test could drift away from.
    func testAKeptCharacterLosesOnlyASliverOfItsInk() throws {
        guard case let .pages(pages)? = DocumentDecoder.decode(try makePDFURL()),
              let page = pages.first else { return XCTFail("the fixture did not decode as pages") }
        let source = page.image.cgImage
        let text = try XCTUnwrap(page.text, "the fixture page has no text layer")
        let rasterSize = CGSize(width: source.width, height: source.height)
        let pageSize = try XCTUnwrap(page.pageSize)
        let scale = rasterSize.width / pageSize.width

        // No character box can hide inside the 2px band: every one is a full line tall. Assert it,
        // because the whole argument below rests on it.
        let heights = Set(text.characters.filter { !$0.character.isWhitespace }
                              .map { ($0.box.height * scale).rounded() })
        XCTAssertEqual(heights, [24], "character boxes are no longer a full line tall, so a glyph "
                       + "could now fit inside the painted band the gate does not cover")

        // A box over line 1 whose bottom edge stops one raster pixel short of line 2, so the paint
        // reaches line 2 and the gate does not.
        let line1Box = try box(of: "usage calls", in: text)
        let line2Box = try box(of: "Output tokens", in: text)
        let bottom = line2Box.maxY + 1 / scale
        let region = raster(CGRect(x: line2Box.minX, y: bottom, width: line2Box.width,
                                   height: line1Box.maxY - bottom),
                            pageHeight: pageSize.height, scale: scale)
        let drawn = DetectedEntity(type: .other("drawn"), value: "", confidence: 1, source: .regex,
                                   locus: .region(region))
        let flattened = try XCTUnwrap(ImageRedactor().flattened(source, entities: [drawn]))
        let painted = try XCTUnwrap(changedPixels(from: source, to: flattened),
                                    "nothing was painted, so this asserts nothing")
        let ink = try XCTUnwrap(bytes(of: source))

        let safe = try XCTUnwrap(PDFTextLayer.sanitized(from: text, redactions: [region],
                                                        rasterSize: rasterSize))
        XCTAssertTrue(String(safe.characters.map(\.character)).contains("Output tokens"),
                      "the line the box stops short of was removed anyway")

        var worst = (share: 0, character: " ")
        for placed in safe.characters where !placed.character.isWhitespace {
            let box = raster(placed.box, pageHeight: pageSize.height, scale: scale)
            let clipped = painted.intersection(box)
            guard !clipped.isNull else { continue }
            let lost = darkPixels(in: clipped, of: ink, width: source.width, height: source.height)
            guard lost > 0 else { continue }
            let total = darkPixels(in: box, of: ink, width: source.width, height: source.height)
            let share = total > 0 ? lost * 100 / total : 100
            if share > worst.share { worst = (share, String(placed.character)) }
        }
        XCTAssertGreaterThan(worst.share, 0, "no kept character lost any ink at all, so the ceiling "
                             + "below is never tested. The fixture stopped building the worst case.")
        XCTAssertLessThanOrEqual(
            worst.share, 25,
            "'\(worst.character)' was kept with \(worst.share)% of its ink painted over. A kept "
            + "character is supposed to stay plainly readable."
        )
    }

    /// Ink is dark pixels in the SOURCE raster, before anything was painted over it.
    private func darkPixels(in rect: CGRect, of pixels: [UInt8], width: Int, height: Int) -> Int {
        var count = 0
        for y in max(0, Int(rect.minY))..<min(Int(rect.maxY.rounded(.up)), height) {
            for x in max(0, Int(rect.minX))..<min(Int(rect.maxX.rounded(.up)), width) {
                let i = (y * width + x) * 4
                if pixels[i] < 100 && pixels[i + 1] < 100 && pixels[i + 2] < 100 { count += 1 }
            }
        }
        return count
    }

    // MARK: - Pseudonym tokens

    /// A pseudonym is written into the box its value came from, so its run is a whole line tall
    /// like a redaction box. The same vertical margin used to let a NEW box one line away drop a
    /// token from a restored export, leaving the page showing a pseudonym the text layer denies.
    func testANewBoxOneLineAwayKeepsARestoredToken() throws {
        let doc = try XCTUnwrap(PDFDocument(data: makePDF()))
        let page = try XCTUnwrap(doc.page(at: 0))
        let text = try XCTUnwrap(PDFPageText.extract(from: page))
        let pageBox = page.bounds(for: .mediaBox)

        for scale in [CGFloat(1), 2] {
            let rasterSize = CGSize(width: pageBox.width * scale, height: pageBox.height * scale)
            let token = PDFTextRun(text: "NAME_4f2a1c", box: try box(of: "Output tokens", in: text))
            let onLine1 = raster(try box(of: "usage calls", in: text),
                                 pageHeight: pageBox.height, scale: scale)
            let onLine2 = raster(token.box, pageHeight: pageBox.height, scale: scale)

            let survives = PDFTextLayer.uncoveredTokens([token], redactions: [onLine1],
                                                        rasterSize: rasterSize, pageSize: pageBox.size)
            XCTAssertEqual(survives.map(\.text), ["NAME_4f2a1c"],
                           "scale \(Int(scale))x: a box on the line above dropped the token")

            let dropped = PDFTextLayer.uncoveredTokens([token], redactions: [onLine2],
                                                       rasterSize: rasterSize, pageSize: pageBox.size)
            XCTAssertTrue(dropped.isEmpty,
                          "scale \(Int(scale))x: a box over the token itself left it extractable")
        }
    }

    /// The assembler suppresses a pseudonym that a SECOND cover sits over. Sideways that test still
    /// grows by the clearance, so a cover two pixels to the side counts. Vertically it no longer
    /// does, or a box on the next line silently removed a pseudonym nothing covers.
    func testASecondCoverSuppressesATokenOnlyWhenItReachesIt() throws {
        guard case let .pages(pages)? = DocumentDecoder.decode(try makePDFURL()),
              let page = pages.first else { return XCTFail("the fixture did not decode as pages") }
        let source = page.image.cgImage
        let text = try XCTUnwrap(page.text, "the fixture page has no text layer")
        let rasterSize = CGSize(width: source.width, height: source.height)
        let pageSize = try XCTUnwrap(page.pageSize)
        let scale = rasterSize.width / pageSize.width

        let tokenRect = raster(try box(of: "SECRETNAME", in: text),
                               pageHeight: pageSize.height, scale: scale)
        let entity = DetectedEntity(type: .name, value: "SECRETNAME", confidence: 1,
                                    source: .regex, locus: .region(tokenRect))
        let tokens = [entity.id: "NAME_4f2a1c"]
        let flattened = try XCTUnwrap(ImageRedactor().flattened(source, entities: [entity],
                                                                tokens: tokens))
        // Neither of the first two covers the token. One is a line below it, one is beside it.
        let below = CGRect(x: tokenRect.minX, y: tokenRect.maxY + 1,
                           width: tokenRect.width, height: 4)
        let beside = CGRect(x: tokenRect.maxX + 2, y: tokenRect.minY,
                            width: 2, height: tokenRect.height)
        for (obscured, wanted) in [(below, true), (beside, false), (tokenRect, false)] {
            let assembled = PDFAssembler.Page.make(
                flattened: flattened, rasterSize: rasterSize, pageSize: pageSize, text: text,
                regions: [entity], obscured: [obscured], tokens: tokens
            )
            let extracted = PDFDocument(data: try XCTUnwrap(PDFAssembler.pdfData(from: [assembled])))?
                .string ?? ""

            XCTAssertEqual(extracted.contains("NAME_4f2a1c"), wanted,
                           "cover \(obscured.integral): the token should "
                           + (wanted ? "survive, and it did not" : "be suppressed, and it was not"))
            XCTAssertFalse(extracted.contains("SECRETNAME"), "the value the token stands for is back")
        }
    }

    /// The union of one value's character boxes, in the unrotated page frame.
    private func box(of value: String, in text: PDFPageText) throws -> CGRect {
        let characters = String(text.characters.map(\.character))
        let range = try XCTUnwrap(characters.range(of: value), "\(value) is not on the page")
        let lower = characters.distance(from: characters.startIndex, to: range.lowerBound)
        var union = CGRect.null
        for offset in 0..<value.count { union = union.union(text.characters[lower + offset].box) }
        return union
    }

    /// Where the two rasters differ, as one rectangle. That is the black the app actually painted.
    private func changedPixels(from before: CGImage, to after: CGImage) -> CGRect? {
        guard let a = bytes(of: before), let b = bytes(of: after), a.count == b.count else { return nil }
        let width = before.width, height = before.height
        var box = CGRect.null
        for y in 0..<height {
            for x in 0..<width where a[(y * width + x) * 4] != b[(y * width + x) * 4] {
                box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return box.isNull ? nil : box
    }

    private func bytes(of image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let ctx = CGContext(data: &pixels, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }
}
