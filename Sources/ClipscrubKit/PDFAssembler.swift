import CoreGraphics
import CoreText
import Foundation

/// Re-assembles redacted page images into a single PDF, one page per image.
///
/// The pixels are flattened, so nothing is hiding under a redaction box: the classic "box drawn
/// over still-extractable text" leak cannot happen. A page may also carry text runs, which are
/// drawn invisibly over the pixels they came from. Those runs are built from characters no
/// redaction touches (`PDFTextLayer`), so the page stays searchable and the removed values are
/// still absent from the file. Pure CoreGraphics and CoreText, no PDFKit/AppKit.
public enum PDFAssembler {
    /// One page: its flattened pixels, the size to emit it at, and any text to make searchable.
    public struct Page: Sendable {
        public let image: CGImage
        /// Page size in points. Emitting the pixel count as points doubled every page a 2x render
        /// produced, so a letter page printed at twice its size.
        public let size: CGSize
        public let textRuns: [PDFTextRun]
        /// Safe source characters after the geometry gate. History persists this subset only.
        public let sanitizedText: PDFPageText?
        /// Safe pseudonyms generated for this page. History restores and gates them again.
        public let tokenRuns: [PDFTextRun]

        public init(image: CGImage, size: CGSize? = nil, textRuns: [PDFTextRun] = [],
                    sanitizedText: PDFPageText? = nil, tokenRuns: [PDFTextRun] = []) {
            self.image = image
            self.size = size ?? CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
            self.textRuns = textRuns
            self.sanitizedText = sanitizedText
            self.tokenRuns = tokenRuns
        }

        /// Build a page from a redaction result. The one place the four export paths agree on what
        /// goes into a page, so a path cannot quietly ship without the geometry gate.
        ///
        /// `flattened` is the redacted bitmap and `rasterSize` the size of the image it was made
        /// from, which is the space `regions` are in. Pass `text: nil` to emit pixels only — that is
        /// what a scanned page, a plain image and the flatten-only setting all come down to.
        ///
        /// `obscured` is for anything that hides content without being a detection — a filled box a
        /// user drew, a blur they painted on. Those are drawn after the flatten and are not regions,
        /// so without them the words under a hand-drawn cover would come back in the text.
        public static func make(
            flattened: CGImage,
            rasterSize: CGSize,
            pageSize: CGSize?,
            text: PDFPageText?,
            regions: [DetectedEntity],
            obscured: [CGRect] = [],
            tokens: [DetectedEntity.ID: String]? = nil,
            retainedTokens: [PDFTextRun] = []
        ) -> Page {
            let emittedSize = pageSize ?? CGSize(width: CGFloat(flattened.width),
                                                  height: CGFloat(flattened.height))
            var covered = obscured
            var placed: [(id: DetectedEntity.ID, rect: CGRect, text: String)] = []
            for region in regions where region.isEnabled {
                guard case let .region(rect) = region.locus else { continue }
                covered.append(rect)
                if let token = tokens?[region.id] { placed.append((region.id, rect, token)) }
            }
            // A token replaces the value in its own region, so that region is allowed. Another
            // enabled region or an opaque annotation still covers it and must keep it out of the
            // extractable layer.
            placed.removeAll { token in
                // Sideways only, matching the character gate. Growing a token's own line-tall rect
                // downward let a box on the next line suppress a pseudonym nothing covers.
                let guarded = token.rect.insetBy(dx: -PDFTextLayer.clearance, dy: 0)
                return obscured.contains(where: { $0.intersects(guarded) })
                    || regions.contains { region in
                        guard region.isEnabled, region.id != token.id,
                              case let .region(rect) = region.locus else { return false }
                        return rect.intersects(guarded)
                    }
            }

            // A scanned page stays pixels-only. A pseudonym becomes searchable only when it
            // replaces text from an existing PDF layer.
            let generatedTokens = text.map { _ in
                PDFTextLayer.tokenRuns(
                    placed.map { ($0.rect, $0.text) }, rasterSize: rasterSize, pageSize: emittedSize
                )
            } ?? []
            let restoredTokens = PDFTextLayer.uncoveredTokens(
                retainedTokens, redactions: covered, rasterSize: rasterSize, pageSize: emittedSize
            )
            var runs = generatedTokens + restoredTokens
            var safeText: PDFPageText?
            if let text {
                safeText = PDFTextLayer.sanitized(from: text, redactions: covered,
                                                  rasterSize: rasterSize)
                runs.insert(contentsOf: PDFTextLayer.runs(from: text, redactions: covered,
                                                          rasterSize: rasterSize), at: 0)
            }
            return Page(image: flattened, size: pageSize, textRuns: runs,
                        sanitizedText: safeText, tokenRuns: generatedTokens + restoredTokens)
        }
    }

    public static func pdfData(from images: [CGImage]) -> Data? {
        pdfData(from: images.map { Page(image: $0) })
    }

    public static func pdfData(from pages: [Page]) -> Data? {
        guard let first = pages.first else { return nil }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var firstBox = CGRect(origin: .zero, size: first.size)
        guard let context = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else { return nil }
        for page in pages {
            var box = CGRect(origin: .zero, size: page.size)
            context.beginPage(mediaBox: &box)
            context.draw(page.image, in: box)
            draw(page.textRuns, in: context)
            context.endPage()
        }
        context.closePDF()
        return withoutDocumentInfo(data as Data)
    }

    /// Blank the values Quartz writes into the PDF's own `/Info` dictionary.
    ///
    /// `/Producer` reads "macOS Version 26.3.1 (a) (Build 25D771280a) Quartz PDFContext" — the
    /// exact OS build of the machine that did the redaction, which fingerprints it far more
    /// precisely than anything the image path ever carried. `/CreationDate` and `/ModDate` say when.
    /// None of it comes from the source document, and all of it is about the person exporting.
    ///
    /// Quartz owns these: an empty auxiliary-info dictionary does not suppress them, and neither
    /// does setting Creator, Title and Author explicitly — measured, all three still emit Producer.
    /// So the values are blanked after the fact.
    ///
    /// In place, preserving byte length. A PDF's cross-reference table stores absolute byte offsets,
    /// so deleting the entries would move every object after them and invalidate the file. Writing
    /// spaces between the parentheses keeps each string a valid PDF string of the same size, and
    /// every offset stays correct. The keys survive with empty values, which is the honest shape:
    /// the file says nothing rather than pretending Quartz never touched it.
    static func withoutDocumentInfo(_ pdf: Data) -> Data {
        var bytes = [UInt8](pdf)
        let open = UInt8(ascii: "("), close = UInt8(ascii: ")"), escape = UInt8(ascii: "\\")

        for key in ["/Producer", "/CreationDate", "/ModDate"] {
            let needle = Array(key.utf8)
            guard needle.count <= bytes.count else { continue }
            guard let keyStart = (0...(bytes.count - needle.count)).first(where: {
                Array(bytes[$0..<$0 + needle.count]) == needle
            }) else { continue }

            // The value follows the key. Anything other than a string literal is left alone.
            var start = keyStart + needle.count
            while start < bytes.count, bytes[start] == UInt8(ascii: " ") { start += 1 }
            guard start < bytes.count, bytes[start] == open else { continue }

            // PDF string literals nest parentheses and escape with a backslash, so this counts
            // depth rather than stopping at the first `)`.
            var depth = 0, end = start
            while end < bytes.count {
                if bytes[end] == escape { end += 2; continue }
                if bytes[end] == open { depth += 1 }
                if bytes[end] == close {
                    depth -= 1
                    if depth == 0 { break }
                }
                end += 1
            }
            guard end < bytes.count, depth == 0, end > start + 1 else { continue }
            for i in (start + 1)..<end { bytes[i] = UInt8(ascii: " ") }
        }
        return Data(bytes)
    }

    /// Draw each run as invisible glyphs across the box its characters occupied.
    ///
    /// Invisible rendering mode rather than a transparent fill: it is what every reader expects of
    /// a searchable scan, and a clear fill needs an alpha state that some renderers treat their own
    /// way. The glyphs are placed a run at a time, squeezed to span the original box, because
    /// placing them one at a time leaves gaps a reader sees as a space between every letter.
    ///
    /// Each run is also tagged. Invisible text alone is extractable and searchable, which is what a
    /// person copying from the file needs — but an untagged page hands a screen reader glyphs with
    /// nothing saying they are text, so what it reads back is up to the reader. A tag per run emits
    /// a structure tree (`/StructTreeRoot`, `/MarkInfo /Marked true`, one `/StructElem /S /P` per
    /// run) and makes the answer a property of the file. `Paragraph` rather than `Span`: a run is a
    /// line of the original page, and a reader that pauses between paragraphs should pause between
    /// lines.
    ///
    /// This is a structure tree, not a conformance claim. Nothing here sets a document language or
    /// a reading order beyond the order the runs are drawn in, so PDF/UA is not on offer.
    private static func draw(_ runs: [PDFTextRun], in context: CGContext) {
        guard !runs.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setTextDrawingMode(.invisible)

        for run in runs where run.box.height > 0 && run.box.width > 0 {
            let turned = run.rotation % 180 != 0
            // On a turned page the words run down the emitted page, so the run's length is its box
            // height and the size of the type is its width.
            let length = turned ? run.box.height : run.box.width
            let size = turned ? run.box.width : run.box.height

            guard let layout = shaped(run.text, size: size), layout.width > 0 else { continue }

            // Opened after the guard above, so a run that draws nothing leaves no empty tag behind.
            //
            // No `ActualText` property. Passing one is a measured no-op here — CoreGraphics writes
            // `/StructElem /S /P` with a marked-content reference and no `/ActualText` key — and a
            // property that does nothing invites the next author to trust it. Were it written, it
            // would put a second cleartext copy of the run in the file, which is a surface this
            // gate would then have to cover as well.
            CGPDFContextBeginTag(context, .paragraph, [:] as CFDictionary)
            defer { CGPDFContextEndTag(context) }

            // Turn the drawing frame rather than the text matrix, so rotation and scaling stay
            // separate and CoreText keeps ownership of the line's text matrix.
            let (origin, angle) = start(of: run)
            context.saveGState()
            context.translateBy(x: origin.x, y: origin.y)
            if angle != 0 { context.rotate(by: angle) }
            // Scale the drawing frame itself. CoreText keeps the source string's bidirectional
            // order, fallback fonts and glyph positions together while the run spans its box.
            context.scaleBy(x: length / layout.width, y: 1)
            context.textPosition = .zero
            CTLineDraw(layout.line, context)
            context.restoreGState()
        }
    }

    /// Lay a run out, letting CoreText pick a font for anything Helvetica cannot draw.
    ///
    /// Helvetica covers Latin, Greek and Cyrillic and stops there. Asking it for the glyphs of a
    /// whole run and giving up when any character came back missing dropped the run WHOLE — so a
    /// Japanese page kept no text at all, and one emoji took the English on either side of it with
    /// it. Neither said anything: the page still exported, just silently unsearchable.
    ///
    /// `CTLine` supplies the fallback fonts, bidirectional order and exact glyph positions. Drawing
    /// that line keeps right-to-left words selectable in place and extractable in logical order.
    private static func shaped(_ text: String, size: CGFloat)
        -> (width: CGFloat, line: CTLine)? {
        let base = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        guard let attributed = CFAttributedStringCreate(
            nil, text as CFString, [kCTFontAttributeName: base] as CFDictionary
        ) else { return nil }
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard width > 0 else { return nil }
        return (width, line)
    }

    /// Where a run's first glyph sits and which way the words run, on a page turned any of the four
    /// ways PDF allows. The corner is the one reading starts from once the page is upright.
    private static func start(of run: PDFTextRun) -> (CGPoint, CGFloat) {
        let box = run.box
        switch ((run.rotation % 360) + 360) % 360 {
        case 90:
            return (CGPoint(x: box.minX, y: box.maxY), -.pi / 2)
        case 180:
            return (CGPoint(x: box.maxX, y: box.maxY), .pi)
        case 270:
            return (CGPoint(x: box.maxX, y: box.minY), .pi / 2)
        default:
            return (CGPoint(x: box.minX, y: box.minY), 0)
        }
    }
}
