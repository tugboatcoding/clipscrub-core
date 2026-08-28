import CoreGraphics
import CoreText
import Foundation
import PDFKit
import XCTest
@testable import ClipscrubKit

/// What a reader can pull out of an exported PDF, asked of the file rather than of the engine.
/// Nothing else in the suite reads the assembled PDF back, so the property the whole document path
/// rests on has never been checked.
final class PDFTextRetentionTests: XCTestCase {
    private let identifiers = ["Dee Okonkwo", "88213", "tobias.renner@example.org", "020 7946 0812"]

    private var lines: [String] {
        ["Patient: \(identifiers[0])    MRN \(identifiers[1])",
         "Seen 14 March 2026 at the Riverside clinic.",
         "Contact \(identifiers[2]) or \(identifiers[3]).",
         "Follow up in six weeks."]
    }

    // MARK: - Fixtures

    /// A PDF with a real text layer, the shape this feature is about. Rotation is applied to the
    /// page so a caller can exercise the space where characterBounds and the raster disagree.
    private func makeTextPDF(rotation: Int = 0, lines: [String]? = nil,
                             font fontName: String = "Helvetica",
                             mediaOrigin: CGPoint = .zero) throws -> URL {
        let lines = lines ?? self.lines
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipscrub-text-\(UUID().uuidString).pdf")
        var box = CGRect(origin: mediaOrigin, size: CGSize(width: 612, height: 792))
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPage(mediaBox: &box)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(box)
        let font = CTFontCreateWithName(fontName as CFString, 12, nil)
        for (index, line) in lines.enumerated() {
            let attributes = [kCTFontAttributeName: font,
                              kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)] as CFDictionary
            let attributed = try XCTUnwrap(CFAttributedStringCreate(nil, line as CFString, attributes))
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: mediaOrigin.x + 72,
                                           y: mediaOrigin.y + 700 - CGFloat(index) * 20)
            CTLineDraw(ctLine, context)
        }
        context.endPage()
        context.closePDF()

        if rotation != 0 {
            let document = try XCTUnwrap(PDFDocument(url: url))
            try XCTUnwrap(document.page(at: 0)).rotation = rotation
            XCTAssertTrue(document.write(to: url))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func extractedText(from data: Data) throws -> String {
        let document = try XCTUnwrap(PDFDocument(data: data), "the exported bytes are not a PDF")
        return document.string ?? ""
    }

    private func decodedPage(_ url: URL) throws -> DecodedPage {
        guard case let .pages(pages)? = DocumentDecoder.decode(url), let page = pages.first else {
            throw XCTSkip("the fixture did not decode as pages")
        }
        return page
    }

    /// Where a value sits in the rendered raster, which is the space redaction regions live in.
    private func rasterRect(of value: String, in page: DecodedPage) throws -> CGRect {
        let text = try XCTUnwrap(page.text, "the fixture page has no text layer")
        let characters = String(text.characters.map(\.character))
        let range = try XCTUnwrap(characters.range(of: value), "\(value) is not on the page")
        let lower = characters.distance(from: characters.startIndex, to: range.lowerBound)
        var union = CGRect.null
        for offset in 0..<value.count { union = union.union(text.characters[lower + offset].box) }

        // Characters are unrotated. Turn the box onto the emitted page before scaling to pixels, or
        // a rotated fixture asks for a redaction somewhere else entirely.
        let emitted = text.size
        let onPage = PDFPageText.turn(union, by: text.rotation, in: text.unrotatedSize)
        let scale = CGFloat(page.image.cgImage.width) / emitted.width
        return CGRect(x: onPage.minX * scale, y: (emitted.height - onPage.maxY) * scale,
                      width: onPage.width * scale, height: onPage.height * scale)
    }

    /// Derive the region from the source PDF rather than from `PDFPageText`. The source character
    /// boxes include the media-box origin, while the rendered raster starts at zero. Using the
    /// extracted text here would let the production bug compute both sides of its own assertion.
    private func sourceRasterRect(of value: String, in url: URL, decoded: DecodedPage) throws -> CGRect {
        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let pageString = try XCTUnwrap(page.string)
        let characters = Array(pageString)
        let range = try XCTUnwrap(pageString.range(of: value))
        let lower = pageString.distance(from: pageString.startIndex, to: range.lowerBound)
        let upper = pageString.distance(from: pageString.startIndex, to: range.upperBound)
        let firstBoxIndex = characters[..<lower].filter { !$0.isNewline }.count
        let boxCount = characters[lower..<upper].filter { !$0.isNewline }.count
        var union = CGRect.null
        for index in firstBoxIndex..<(firstBoxIndex + boxCount) {
            union = union.union(page.characterBounds(at: index))
        }

        let bounds = page.bounds(for: .mediaBox)
        let local = union.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        let rotation = ((page.rotation % 360) + 360) % 360
        let emitted = rotation % 180 == 0
            ? bounds.size
            : CGSize(width: bounds.height, height: bounds.width)
        let visual: CGRect
        switch rotation {
        case 90:
            visual = CGRect(x: local.minY, y: bounds.width - local.maxX,
                            width: local.height, height: local.width)
        case 180:
            visual = CGRect(x: bounds.width - local.maxX, y: bounds.height - local.maxY,
                            width: local.width, height: local.height)
        case 270:
            visual = CGRect(x: bounds.height - local.maxY, y: local.minX,
                            width: local.height, height: local.width)
        default:
            visual = local
        }
        let scale = CGFloat(decoded.image.cgImage.width) / emitted.width
        return CGRect(x: visual.minX * scale, y: (emitted.height - visual.maxY) * scale,
                      width: visual.width * scale, height: visual.height * scale)
    }

    /// Run the real export: flatten the regions into the page, then assemble with the text layer.
    private func export(_ page: DecodedPage, covering values: [String],
                        tokens: [String: String] = [:]) throws -> Data {
        let source = page.image.cgImage
        var regions: [DetectedEntity] = []
        var tokenMap: [DetectedEntity.ID: String] = [:]
        for value in values {
            let entity = DetectedEntity(type: .name, value: value, confidence: 1, source: .regex,
                                        locus: .region(try rasterRect(of: value, in: page)))
            regions.append(entity)
            if let token = tokens[value] { tokenMap[entity.id] = token }
        }
        let flattened = try XCTUnwrap(ImageRedactor().flattened(source, entities: regions,
                                                               tokens: tokenMap.isEmpty ? nil : tokenMap))
        let assembled = PDFAssembler.Page.make(
            flattened: flattened,
            rasterSize: CGSize(width: source.width, height: source.height),
            pageSize: page.pageSize,
            text: page.text,
            regions: regions,
            tokens: tokenMap.isEmpty ? nil : tokenMap
        )
        return try XCTUnwrap(PDFAssembler.pdfData(from: [assembled]))
    }

    // MARK: - Tests

    /// The property the raster export has always claimed and nothing has ever asserted. It has to
    /// keep holding for a flatten-only export after the text layer lands.
    func testFlattenOnlyExportLeavesNothingToExtract() throws {
        let url = try makeTextPDF()
        guard case let .pages(pages)? = DocumentDecoder.decode(url) else {
            return XCTFail("the fixture did not decode as pages")
        }
        let data = try XCTUnwrap(PDFAssembler.pdfData(from: pages.map(\.image.cgImage)))

        let extracted = try extractedText(from: data)
        XCTAssertTrue(extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "a flattened export handed back text: \"\(extracted)\"")
        for identifier in identifiers {
            XCTAssertFalse(extracted.contains(identifier), "\(identifier) survived a flattened export")
        }
    }

    /// The fixture has to actually carry the identifiers, or the test above passes on an empty page
    /// and proves nothing. Same reasoning as the detection gate's empty-text rule.
    func testTheFixtureItselfCarriesEveryIdentifier() throws {
        let url = try makeTextPDF()
        let source = try XCTUnwrap(PDFDocument(url: url)?.string)
        for identifier in identifiers {
            XCTAssertTrue(source.contains(identifier), "\(identifier) is missing from the fixture")
        }
    }

    /// The claim in one test: the redacted PDF says what the original said, minus what was removed.
    func testExportKeepsEveryWordItDidNotRedact() throws {
        let page = try decodedPage(try makeTextPDF())
        let data = try export(page, covering: ["Dee Okonkwo"])
        let extracted = try extractedText(from: data)

        XCTAssertFalse(extracted.contains("Dee Okonkwo"), "the redacted name is extractable")
        XCTAssertFalse(extracted.contains("Okonkwo"), "half the redacted name is extractable")
        for kept in ["Riverside", "88213", "tobias.renner@example.org", "Follow up in six weeks"] {
            XCTAssertTrue(extracted.contains(kept), "\(kept) was not redacted and did not survive")
        }
    }

    /// Extractable is not the same as readable. Invisible text gives a person copying from the file
    /// what they need; a screen reader gets glyphs with nothing saying they are text, so what it
    /// reads back is the reader's guess. The tags make it a property of the file instead.
    ///
    /// Asserted on the emitted bytes rather than through a reader, because the structure tree is
    /// what we control — how any one screen reader speaks it is not.
    func testTheExportedPDFCarriesAStructureTreeAScreenReaderCanUse() throws {
        let page = try decodedPage(try makeTextPDF())
        let data = try export(page, covering: ["Dee Okonkwo"])
        let pdf = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(pdf.contains("/StructTreeRoot"), "the export has no structure tree")
        XCTAssertTrue(pdf.contains("/MarkInfo"), "the export does not declare itself marked")
        XCTAssertTrue(pdf.contains("/Marked true"), "the export declares MarkInfo without Marked")
    }

    /// The export names neither the machine that made it nor the moment it was made.
    ///
    /// Quartz writes its own /Info dictionary: /Producer carries the exact macOS build number, and
    /// /CreationDate and /ModDate carry the timestamp. That is a fingerprint of the person doing the
    /// redaction, which is the one party a de-identification tool has no business describing.
    func testTheExportedPDFNamesNeitherTheMachineNorTheMoment() throws {
        let page = try decodedPage(try makeTextPDF())
        let data = try export(page, covering: ["Dee Okonkwo"])
        let pdf = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(pdf.contains("Quartz PDFContext"), "the PDF names the framework that wrote it")
        XCTAssertFalse(pdf.contains("Build "), "the PDF carries the machine's OS build number")
        XCTAssertFalse(pdf.contains("macOS Version"), "the PDF names the machine's OS version")
        // A date literal in any year, so this does not quietly start passing in January.
        XCTAssertNil(pdf.range(of: #"D:\d{8}"#, options: .regularExpression),
                     "the PDF carries the timestamp of the redaction")
        // The blanking must not have broken the file: the offsets in the xref table are absolute.
        XCTAssertNotNil(PDFDocument(data: data)?.page(at: 0), "the PDF no longer opens")
    }

    /// Blanking is length-preserving, asserted on bytes this test controls.
    ///
    /// A PDF xref stores absolute byte offsets, so a fix that SHORTENED the file would leave every
    /// later object unreachable. The obvious test — round-trip a real export and compare lengths —
    /// cannot fail: `pdfData` already blanked it, so the values are spaces by then and a second pass
    /// is a no-op whether the code overwrites or deletes. So the input is built here, unblanked.
    func testBlankingTheInfoDictionaryChangesNoOffsets() throws {
        let source = Data("""
        1 0 obj
        << /Producer (macOS Version 26.3.1 \\(a\\) Quartz PDFContext) /ModDate (D:20260822151601Z) >>
        endobj
        """.utf8)
        let blanked = PDFAssembler.withoutDocumentInfo(source)
        let text = String(decoding: blanked, as: UTF8.self)

        XCTAssertEqual(blanked.count, source.count, "blanking moved every xref offset after it")
        XCTAssertFalse(text.contains("Quartz"), "the producer string survived")
        XCTAssertFalse(text.contains("D:2026"), "the timestamp survived")
        XCTAssertTrue(text.contains("/Producer ("), "the key and its parentheses must remain")
        // A nested escaped paren inside the string must not end it early and leave a tail behind.
        XCTAssertFalse(text.contains("26.3.1"), "the scan stopped at an escaped parenthesis")
    }

    /// Quartz output can contain an earlier metadata object before the active document info.
    /// Every matching string must be blanked because the bytes remain searchable after export.
    func testBlankingRemovesEveryOccurrenceOfAnInfoValue() throws {
        let source = Data("""
        1 0 obj
        << /CreationDate (D:20260822151601Z) >>
        endobj
        2 0 obj
        << /CreationDate (D:20260828131343Z) >>
        endobj
        """.utf8)
        let blanked = PDFAssembler.withoutDocumentInfo(source)
        let text = String(decoding: blanked, as: UTF8.self)

        XCTAssertEqual(blanked.count, source.count, "blanking moved the later object")
        XCTAssertNil(text.range(of: #"D:\d{8}"#, options: .regularExpression),
                     "a later document-info timestamp survived")
    }

    /// A value that is not a string literal is left alone rather than guessed at.
    func testANonStringInfoValueIsLeftUntouched() throws {
        let source = Data("<< /Producer 4 0 R /ModDate (D:20260822151601Z) >>".utf8)
        let text = String(decoding: PDFAssembler.withoutDocumentInfo(source), as: UTF8.self)

        XCTAssertTrue(text.contains("/Producer 4 0 R"), "an indirect reference was mangled")
        XCTAssertFalse(text.contains("D:2026"), "the string value beside it was skipped")
    }

    /// One structure element per drawn run, so the tags track the text rather than the page.
    ///
    /// Deliberately NOT a substring scan for a redacted value in the emitted bytes. That test was
    /// written first and it could not fail: CoreText draws glyph codes against a subset font, so
    /// measured on a file whose visible text IS the secret, neither the raw bytes nor the inflated
    /// streams contain it. Extraction is what sees through that, and
    /// `testExportKeepsEveryWordItDidNotRedact` already asserts it — with the tags now on.
    func testEveryDrawnRunGetsItsOwnStructureElement() throws {
        let page = try decodedPage(try makeTextPDF())
        let data = try export(page, covering: ["Dee Okonkwo"])
        let pdf = String(decoding: data, as: UTF8.self)

        let runs = try XCTUnwrap(PDFAssembler.Page.make(
            flattened: page.image.cgImage,
            rasterSize: CGSize(width: page.image.cgImage.width, height: page.image.cgImage.height),
            pageSize: page.pageSize, text: page.text, regions: [], tokens: nil
        ).textRuns.count as Int?)
        XCTAssertGreaterThan(runs, 0, "the fixture produced no text runs, so this asserts nothing")

        let elements = pdf.components(separatedBy: "/S /P").count - 1
        XCTAssertGreaterThanOrEqual(
            elements, runs,
            "\(runs) run(s) drawn but only \(elements) paragraph element(s) in the structure tree"
        )
    }

    /// Geometry is the gate, so a box with no detection behind it — a hand-drawn one — has to take
    /// the text under it as well. Nothing about this case involves the detection engine.
    func testABoxWithNoDetectionBehindItStillRemovesTheTextUnderneath() throws {
        let page = try decodedPage(try makeTextPDF())
        let source = page.image.cgImage
        let drawn = DetectedEntity(type: .other("drawn"), value: "", confidence: 1, source: .regex,
                                   locus: .region(try rasterRect(of: "Riverside", in: page)))
        let flattened = try XCTUnwrap(ImageRedactor().flattened(source, entities: [drawn]))
        let assembled = PDFAssembler.Page.make(
            flattened: flattened, rasterSize: CGSize(width: source.width, height: source.height),
            pageSize: page.pageSize, text: page.text, regions: [drawn]
        )
        let extracted = try extractedText(from: try XCTUnwrap(PDFAssembler.pdfData(from: [assembled])))

        XCTAssertFalse(extracted.contains("Riverside"), "text under a hand-drawn box is extractable")
        XCTAssertTrue(extracted.contains("Dee Okonkwo"), "the box took text it does not cover")
    }

    /// `characterBounds` ignores the page rotation and `thumbnail` applies it. Compose those wrong and
    /// the rectangle lands somewhere else on the page, so a covered value is written back as clear text.
    func testARotatedPageMapsRedactionsOntoTheSameCharacters() throws {
        for rotation in [90, 180, 270] {
            let page = try decodedPage(try makeTextPDF(rotation: rotation))
            let data = try export(page, covering: ["Dee Okonkwo"])
            let extracted = try extractedText(from: data)

            XCTAssertFalse(extracted.contains("Dee Okonkwo"), "rotation \(rotation) leaked the name")
            XCTAssertTrue(extracted.contains("Riverside"), "rotation \(rotation) lost text it did not cover")
        }
    }

    /// A PDF may place its media box away from (0, 0). The raster still starts at zero, so keeping
    /// that offset on character boxes makes the geometry gate miss the covered value.
    func testAShiftedMediaBoxCannotMoveCoveredTextPastTheGate() throws {
        for rotation in [0, 90, 180, 270] {
            let url = try makeTextPDF(rotation: rotation, mediaOrigin: CGPoint(x: 20, y: 20))
            let page = try decodedPage(url)
            let source = page.image.cgImage
            let covered = try sourceRasterRect(of: "Dee Okonkwo", in: url, decoded: page)
            let entity = DetectedEntity(type: .name, value: "Dee Okonkwo", confidence: 1,
                                        source: .regex, locus: .region(covered))
            let flattened = try XCTUnwrap(ImageRedactor().flattened(source, entities: [entity]))
            let assembled = PDFAssembler.Page.make(
                flattened: flattened, rasterSize: CGSize(width: source.width, height: source.height),
                pageSize: page.pageSize, text: page.text, regions: [entity]
            )
            let data = try XCTUnwrap(PDFAssembler.pdfData(from: [assembled]))
            let extracted = try extractedText(from: data)

            XCTAssertFalse(extracted.contains("Dee Okonkwo"),
                           "rotation \(rotation): the shifted media box leaked the name")
            XCTAssertTrue(extracted.contains("Riverside"),
                          "rotation \(rotation): text outside the cover was lost")
        }
    }

    /// A scanned page has no text to keep. Its text would have to come from OCR, and OCR mistakes
    /// written into the file as if they were the document is worse than leaving it as pixels.
    func testAPageWithNoTextLayerExportsPixelsOnly() throws {
        let blank = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        blank.setFillColor(CGColor(gray: 1, alpha: 1))
        blank.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try XCTUnwrap(blank.makeImage())
        let region = DetectedEntity(type: .name, value: "OCR guess", confidence: 1,
                                    source: .vision,
                                    locus: .region(CGRect(x: 20, y: 20, width: 80, height: 20)))

        let assembled = PDFAssembler.Page.make(
            flattened: image, rasterSize: CGSize(width: 400, height: 300),
            pageSize: nil, text: nil, regions: [region], tokens: [region.id: "NAME_123"]
        )
        XCTAssertTrue(assembled.textRuns.isEmpty)
        let extracted = try extractedText(from: try XCTUnwrap(PDFAssembler.pdfData(from: [assembled])))
        XCTAssertTrue(extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Helvetica covers Latin, Greek and Cyrillic and stops. Asking it for a whole run's glyphs and
    /// giving up when any came back missing dropped the run WHOLE, so a Japanese page kept no text
    /// and one emoji took the English either side of it. Nothing said so — the page still exported.
    func testAWordHelveticaCannotDrawDoesNotTakeTheLineWithIt() throws {
        let lines = ["Patient 😀 attended", "東京都渋谷区の病院", "Приём в Москве", "مستشفى النهر"]
        let url = try makeTextPDF(lines: lines, font: "Hiragino Sans")
        let page = try decodedPage(url)
        let extracted = try extractedText(from: try export(page, covering: []))

        for line in lines {
            XCTAssertTrue(extracted.contains(line), "\"\(line)\" is missing from: \(extracted)")
        }
    }

    /// Something drawn over the page hides it on screen without being a detection, so it has to be
    /// handed in separately. Miss it and a hand-drawn cover hands its contents back to anyone who
    /// selects the page — worse than not covering it, because the screen says it is gone.
    func testSomethingDrawnOverThePageTakesTheTextUnderIt() throws {
        let page = try decodedPage(try makeTextPDF())
        let source = page.image.cgImage
        let cover = try rasterRect(of: "Riverside", in: page)

        let assembled = PDFAssembler.Page.make(
            flattened: source, rasterSize: CGSize(width: source.width, height: source.height),
            pageSize: page.pageSize, text: page.text, regions: [], obscured: [cover]
        )
        let extracted = try extractedText(from: try XCTUnwrap(PDFAssembler.pdfData(from: [assembled])))

        XCTAssertFalse(extracted.contains("Riverside"), "text under a drawn cover is extractable")
        XCTAssertTrue(extracted.contains("Dee Okonkwo"), "the cover took text it does not sit on")
    }

    /// Pseudonymise puts the token where the value was, so the export is searchable AND joinable —
    /// the same token for the same value, which is what makes a redacted dataset still countable.
    func testPseudonymiseWritesTheTokenIntoTheSearchableText() throws {
        let page = try decodedPage(try makeTextPDF())
        let data = try export(page, covering: ["Dee Okonkwo"], tokens: ["Dee Okonkwo": "NAME_4f2a1c"])
        let extracted = try extractedText(from: data)

        XCTAssertTrue(extracted.contains("NAME_4f2a1c"), "the token is not searchable")
        XCTAssertFalse(extracted.contains("Dee Okonkwo"), "the value it stands for is still there")
    }

    /// A token is allowed through its own replacement region. An opaque annotation is a second
    /// cover, so leaving the token extractable under it would disagree with the page the reader sees.
    func testAnOpaqueAnnotationAlsoRemovesThePseudonymTokenUnderIt() throws {
        let page = try decodedPage(try makeTextPDF())
        let source = page.image.cgImage
        let covered = try rasterRect(of: "Dee Okonkwo", in: page)
        let entity = DetectedEntity(type: .name, value: "Dee Okonkwo", confidence: 1,
                                    source: .regex, locus: .region(covered))
        let tokens = [entity.id: "NAME_4f2a1c"]
        let flattened = try XCTUnwrap(ImageRedactor().flattened(source, entities: [entity], tokens: tokens))
        let adjacent = CGRect(x: covered.maxX + 2, y: covered.minY,
                              width: 2, height: covered.height)
        for opaque in [covered, adjacent] {
            let assembled = PDFAssembler.Page.make(
                flattened: flattened, rasterSize: CGSize(width: source.width, height: source.height),
                pageSize: page.pageSize, text: page.text, regions: [entity],
                obscured: [opaque], tokens: tokens
            )
            let extracted = try extractedText(
                from: try XCTUnwrap(PDFAssembler.pdfData(from: [assembled]))
            )

            XCTAssertFalse(extracted.contains("NAME_4f2a1c"), "the covered token stayed extractable")
            XCTAssertFalse(extracted.contains("Dee Okonkwo"), "the original value stayed extractable")
            XCTAssertTrue(extracted.contains("Riverside"), "the opaque cover removed unrelated text")
        }
    }

    /// History stores safe characters instead of the original page. It must also remember where a
    /// covered character split a run, or later reconstruction stretches its neighbours across it.
    func testSanitizedTextKeepsTheRunBreakCreatedByACoveredCharacter() throws {
        let boxes = [
            CGRect(x: 0, y: 10, width: 10, height: 10),
            CGRect(x: 10, y: 10, width: 10, height: 10),
            CGRect(x: 25, y: 10, width: 5, height: 10),
            CGRect(x: 35, y: 10, width: 10, height: 10),
            CGRect(x: 45, y: 10, width: 10, height: 10),
        ]
        let placed = zip(Array("ABXCD"), boxes).map {
            PDFPageText.Placed(character: $0.0, box: $0.1)
        }
        let text = PDFPageText(characters: placed, unrotatedSize: CGSize(width: 100, height: 50),
                               rotation: 0)
        let safe = try XCTUnwrap(PDFTextLayer.sanitized(
            from: text, redactions: [CGRect(x: 25, y: 30, width: 5, height: 10)],
            rasterSize: CGSize(width: 100, height: 50)
        ))

        let runs = PDFTextLayer.runs(from: safe, redactions: [],
                                     rasterSize: CGSize(width: 100, height: 50))
        XCTAssertEqual(runs.map(\.text), ["AB", "CD"])
        guard runs.count == 2 else { return }
        XCTAssertLessThanOrEqual(runs[0].box.maxX, 20)
        XCTAssertGreaterThanOrEqual(runs[1].box.minX, 35)
    }

    /// The page was emitted at its pixel count, so a 2x render of a letter page printed at twice its
    /// size. Text placement needs the point size, and so does anyone printing the result.
    func testExportedPageKeepsTheOriginalPointSize() throws {
        let page = try decodedPage(try makeTextPDF())
        let data = try export(page, covering: [])
        let exported = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))

        XCTAssertEqual(exported.bounds(for: .mediaBox).width, 612, accuracy: 1)
        XCTAssertEqual(exported.bounds(for: .mediaBox).height, 792, accuracy: 1)
    }

    /// Extractable is not the same as usable. If the glyphs land beside the word instead of on it, a
    /// reader drag-selects one thing and copies another, which is what this layer is judged on.
    ///
    /// Asked through `selection(for:)` because that is the hit-testing a viewer does. Unioning
    /// `characterBounds` instead reports rotated text in the text's own frame, so a correctly placed
    /// word on a turned page reads as being off the side of the page.
    func testSelectionLandsOnTheWordItCameFrom() throws {
        for rotation in [0, 90, 180, 270] {
            let page = try decodedPage(try makeTextPDF(rotation: rotation))
            let source = try XCTUnwrap(page.text)
            let visual = PDFPageText.turn(try unrotatedBox(of: "Riverside", in: source),
                                          by: source.rotation, in: source.unrotatedSize)

            let data = try export(page, covering: [])
            let exported = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
            let picked = exported.selection(for: visual.insetBy(dx: -1, dy: -1))?.string

            XCTAssertEqual(picked, "Riverside",
                           "rotation \(rotation): selecting where the word is returned \(picked ?? "nothing")")
        }
    }

    /// CoreText owns bidirectional glyph order and placement. Extraction alone can pass while the
    /// selection boxes sit beside an Arabic word, so exercise the reader's hit-testing too.
    func testArabicSelectionLandsOnTheWordItCameFrom() throws {
        let url = try makeTextPDF(lines: ["Patient مستشفى Riverside"], font: "Geeza Pro")
        let page = try decodedPage(url)
        let source = try XCTUnwrap(page.text)
        let visual = try unrotatedBox(of: "مستشفى", in: source)
        let sourcePage = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        XCTAssertEqual(sourcePage.selection(for: visual.insetBy(dx: -1, dy: -1))?.string, "مستشفى")
        XCTAssertTrue(try XCTUnwrap(sourcePage.string).contains("Patient مستشفى Riverside"),
                      "source: \(sourcePage.string ?? "nothing")")
        let data = try export(page, covering: [])
        let exported = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        let extracted = try extractedText(from: data)

        XCTAssertEqual(exported.selection(for: visual.insetBy(dx: -1, dy: -1))?.string, "مستشفى")
        XCTAssertTrue(extracted.contains("Patient مستشفى Riverside"), "extracted: \(extracted)")
    }

    private func unrotatedBox(of value: String, in text: PDFPageText) throws -> CGRect {
        let characters = String(text.characters.map(\.character))
        let range = try XCTUnwrap(characters.range(of: value))
        let lower = characters.distance(from: characters.startIndex, to: range.lowerBound)
        var union = CGRect.null
        for offset in 0..<value.count { union = union.union(text.characters[lower + offset].box) }
        return union
    }

    /// PDFKit counts a line break in `page.string` and skips it in `characterBounds`, so every index
    /// after one is off by one. Reading a rect onto the wrong character is how text under a box ships.
    func testCharacterBoundsSkipTheNewlinesThatPageStringCounts() throws {
        let url = try makeTextPDF()
        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let text = try XCTUnwrap(page.string)
        let characters = Array(text)
        let newlines = characters.filter(\.isNewline).count

        XCTAssertGreaterThan(newlines, 0, "a single-line fixture cannot show the off-by-one")
        XCTAssertEqual(characters.count, page.numberOfCharacters)

        // Walking in lockstep, skipping newlines, has to land every glyph on a real box.
        var boundsIndex = 0
        for character in characters where !character.isNewline {
            let bounds = page.characterBounds(at: boundsIndex)
            XCTAssertNotEqual(bounds, .zero, "'\(character)' at bounds index \(boundsIndex) has no box")
            boundsIndex += 1
        }
        XCTAssertEqual(boundsIndex + newlines, page.numberOfCharacters)
    }
}
