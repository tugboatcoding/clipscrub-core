import CoreGraphics
import Foundation
import PDFKit

/// A stretch of text to write into the exported PDF, invisibly, over the pixels it came from.
public struct PDFTextRun: Sendable, Equatable, Codable {
    public let text: String
    /// The box the text occupies on the emitted page: rotation-normalised points, bottom-left origin.
    public let box: CGRect
    /// The page's own rotation. On a turned page the words run down the emitted page rather than
    /// across it, so the glyphs have to be drawn turned the same way.
    public let rotation: Int

    public init(text: String, box: CGRect, rotation: Int = 0) {
        self.text = text
        self.box = box
        self.rotation = rotation
    }
}

/// A PDF page's own text, with the box each character occupies, read once at decode time.
///
/// Carrying this rather than the `PDFPage` is what lets the text survive the trip to export: a page
/// cannot cross to another actor and cannot outlive its document, and this can do both. Boxes are
/// kept as PDFKit reports them, before the page's rotation — that is the frame where a line of text
/// runs left to right, which is what makes grouping words possible at all.
public struct PDFPageText: Sendable, Equatable, Codable {
    public struct Placed: Sendable, Equatable, Codable {
        public let character: Character
        /// Unrotated page points, bottom-left origin.
        public let box: CGRect
        /// A removed character preceded this one, so reconstruction must start another run here.
        public let startsRun: Bool

        public init(character: Character, box: CGRect, startsRun: Bool = false) {
            self.character = character
            self.box = box
            self.startsRun = startsRun
        }

        private enum CodingKeys: String, CodingKey { case character, box, startsRun }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let string = try values.decode(String.self, forKey: .character)
            guard string.count == 1, let character = string.first else {
                throw DecodingError.dataCorruptedError(
                    forKey: .character, in: values, debugDescription: "Expected one character"
                )
            }
            self.character = character
            box = try values.decode(CGRect.self, forKey: .box)
            startsRun = try values.decodeIfPresent(Bool.self, forKey: .startsRun) ?? false
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(String(character), forKey: .character)
            try values.encode(box, forKey: .box)
            if startsRun { try values.encode(true, forKey: .startsRun) }
        }
    }

    public let characters: [Placed]
    /// The page box before rotation, which is the frame `characters` are in.
    public let unrotatedSize: CGSize
    public let rotation: Int

    /// The size the page is emitted at, after its rotation.
    public var size: CGSize {
        rotation % 180 == 0
            ? unrotatedSize
            : CGSize(width: unrotatedSize.height, height: unrotatedSize.width)
    }

    public var isEmpty: Bool { characters.isEmpty }

    public init(characters: [Placed], unrotatedSize: CGSize, rotation: Int) {
        self.characters = characters
        self.unrotatedSize = unrotatedSize
        self.rotation = ((rotation % 360) + 360) % 360
    }

    /// Read a page's characters and their boxes. Returns nil for a page with no text layer, which
    /// is the scanned case — its text would have to come from OCR, and OCR mistakes written into a
    /// file as if they were the document is worse than leaving it as pixels.
    public static func extract(from page: PDFPage) -> PDFPageText? {
        guard page.numberOfCharacters > 0, let text = page.string, !text.isEmpty else { return nil }

        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        var placed: [Placed] = []
        let source = text as NSString
        var offset = 0
        while offset < source.length {
            let range = source.rangeOfComposedCharacterSequence(at: offset)
            defer { offset = NSMaxRange(range) }
            guard let character = source.substring(with: range).first, !character.isNewline,
                  let selection = page.selection(for: range) else { continue }
            // Text ranges preserve PDFKit's character-to-box mapping across ligatures,
            // supplementary-plane characters and bidirectional runs. A glyph-index walk loses
            // those mappings and can silently omit a character.
            let sourceBox = selection.bounds(for: page)
            guard sourceBox != .zero, !sourceBox.isNull, !sourceBox.isInfinite,
                  sourceBox.width > 0 else { continue }
            // A media box may start away from zero. PDFKit selection bounds keep that origin while
            // the thumbnail starts at (0, 0), so carrying it forward moves the geometry gate away
            // from the pixels it protects.
            let box = sourceBox.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            placed.append(Placed(character: character, box: box))
        }
        guard !placed.isEmpty else { return nil }
        return PDFPageText(characters: placed, unrotatedSize: bounds.size,
                           rotation: ((page.rotation % 360) + 360) % 360)
    }

    /// Turn a rectangle by a quarter turn within a page of `pageSize`. PDFKit's `bounds(for:)` and
    /// `characterBounds(at:)` both ignore the page's rotation while `thumbnail` applies it, so this
    /// is the step that puts characters and redaction boxes in one frame.
    ///
    /// 90 and 270 undo each other and 180 undoes itself, so the same function inverts a mapping by
    /// being handed the complementary angle and the size of the frame being left.
    static func turn(_ rect: CGRect, by rotation: Int, in pageSize: CGSize) -> CGRect {
        switch ((rotation % 360) + 360) % 360 {
        case 90:
            return CGRect(x: rect.minY, y: pageSize.width - rect.maxX,
                          width: rect.height, height: rect.width)
        case 180:
            return CGRect(x: pageSize.width - rect.maxX, y: pageSize.height - rect.maxY,
                          width: rect.width, height: rect.height)
        case 270:
            return CGRect(x: pageSize.height - rect.maxY, y: rect.minX,
                          width: rect.height, height: rect.width)
        default:
            return rect
        }
    }
}

/// Decides which of a page's characters may be written back into the redacted export.
///
/// A character qualifies on geometry alone: its box has to be clear of every redaction rectangle,
/// whatever produced that rectangle. Detection decides what gets covered. It never decides that a
/// character is safe to emit — asking the engine to confirm its own output only re-finds what it
/// already found, so an identifier it missed would go from visible in the image to invisible and
/// machine-readable.
public enum PDFTextLayer {
    /// Grown by this many raster pixels before something is tested against it. `ImageRedactor`
    /// paints each box 2px larger than the region and a glyph touching that edge is unreadable
    /// anyway, so the margin only ever costs a neighbouring character. Characters are grown
    /// sideways only — see `sanitized`.
    public static let clearance: CGFloat = 4

    /// Runs to draw, given the page's text and the boxes that were painted over it.
    ///
    /// `redactions` are in the pixel space of the rendered page image, top-left origin, which is
    /// where `DetectedEntity.region` loci live. `rasterSize` is that image's size, and the scale
    /// between the two frames is derived from it rather than assumed. `tokens` place pseudonyms in
    /// the boxes their values were removed from, so the export is searchable and still joinable.
    public static func runs(
        from text: PDFPageText,
        redactions: [CGRect],
        rasterSize: CGSize,
        tokens: [(rect: CGRect, text: String)] = []
    ) -> [PDFTextRun] {
        guard let safe = sanitized(from: text, redactions: redactions,
                                   rasterSize: rasterSize) else {
            return tokenRuns(tokens, rasterSize: rasterSize, pageSize: text.size)
        }
        var runs = group(safe.characters, blocked: []).map {
            PDFTextRun(text: $0.text,
                       box: PDFPageText.turn($0.box, by: safe.rotation, in: safe.unrotatedSize),
                       rotation: safe.rotation)
        }
        runs += tokenRuns(tokens, rasterSize: rasterSize, pageSize: safe.size)
        return runs
    }

    /// Keep only characters whose source pixels remain visible. History persists this reduced value,
    /// so a removed identifier never enters its encrypted payload and cannot return after restore.
    public static func sanitized(
        from text: PDFPageText,
        redactions: [CGRect],
        rasterSize: CGSize
    ) -> PDFPageText? {
        let emitted = text.size
        guard !text.isEmpty, rasterSize.width > 0, emitted.width > 0 else { return nil }
        let scale = rasterSize.width / emitted.width
        guard scale > 0 else { return nil }

        let margin = clearance / scale
        // Characters are in the unrotated frame, so the rectangles have to come back to meet them.
        // The margin goes on sideways only. A box is drawn around a whole line, so growing it
        // downward reaches the line beneath and deletes words the page still shows. What that
        // costs is the outer 2px of paint over a kept character's box edge, which
        // ClearanceBleedTests measures against the pixels the app actually paints.
        let blocked = redactions.map { rect -> CGRect in
            let onPage = pagePoints(rect, scale: scale, height: emitted.height)
            return PDFPageText.turn(onPage, by: 360 - text.rotation, in: emitted)
                .insetBy(dx: -margin, dy: 0)
        }

        var characters: [PDFPageText.Placed] = []
        var followsCover = false
        for placed in text.characters {
            if blocked.contains(where: { $0.intersects(placed.box) }) {
                followsCover = true
                continue
            }
            characters.append(PDFPageText.Placed(
                character: placed.character, box: placed.box,
                startsRun: placed.startsRun || followsCover
            ))
            followsCover = false
        }
        guard !characters.isEmpty else { return nil }
        return PDFPageText(characters: characters, unrotatedSize: text.unrotatedSize,
                           rotation: text.rotation)
    }

    /// Convert safe pseudonym tokens from raster rectangles to emitted-page runs.
    public static func tokenRuns(
        _ tokens: [(rect: CGRect, text: String)],
        rasterSize: CGSize,
        pageSize: CGSize
    ) -> [PDFTextRun] {
        guard rasterSize.width > 0, pageSize.width > 0 else { return [] }
        let scale = rasterSize.width / pageSize.width
        guard scale > 0 else { return [] }
        return tokens.map {
            PDFTextRun(text: $0.text,
                       box: pagePoints($0.rect, scale: scale, height: pageSize.height))
        }
    }

    /// Reapply later covers to pseudonym runs restored from History.
    public static func uncoveredTokens(
        _ runs: [PDFTextRun],
        redactions: [CGRect],
        rasterSize: CGSize,
        pageSize: CGSize
    ) -> [PDFTextRun] {
        guard !runs.isEmpty, rasterSize.width > 0, pageSize.width > 0 else { return [] }
        let scale = rasterSize.width / pageSize.width
        guard scale > 0 else { return [] }
        let margin = clearance / scale
        // Sideways only, for the reason `sanitized` gives. A token run is a whole line tall too, so
        // a new box one line away used to drop a pseudonym the page still shows.
        let blocked = redactions.map {
            pagePoints($0, scale: scale, height: pageSize.height)
                .insetBy(dx: -margin, dy: 0)
        }
        return runs.filter { run in !blocked.contains(where: { $0.intersects(run.box) }) }
    }

    /// Raster pixels, top-left origin -> emitted page points, bottom-left origin.
    private static func pagePoints(_ rect: CGRect, scale: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: rect.minX / scale, y: height - rect.maxY / scale,
               width: rect.width / scale, height: rect.height / scale)
    }

    private struct Grouped {
        let text: String
        let box: CGRect
    }

    /// Collect uncovered characters into runs, in the unrotated frame where a line reads left to
    /// right. A run breaks at a covered character, a new line or a gap too wide to be a space —
    /// stretching one run across a table row would put its text under the wrong columns.
    private static func group(_ characters: [PDFPageText.Placed], blocked: [CGRect]) -> [Grouped] {
        var runs: [Grouped] = []
        var text = ""
        var box = CGRect.null
        var previous: CGRect?

        func flush() {
            defer { text = ""; box = .null; previous = nil }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !box.isNull, box.width > 0, box.height > 0 else { return }
            runs.append(Grouped(text: trimmed, box: box))
        }

        for placed in characters {
            if placed.startsRun { flush() }
            guard !blocked.contains(where: { $0.intersects(placed.box) }) else { flush(); continue }
            if let previous {
                // Font fallback can change a glyph's ascent and descent within one baseline. The
                // vertical spans still overlap, while separate lines do not.
                let sameLine = placed.box.maxY > previous.minY && previous.maxY > placed.box.minY
                let gap = placed.box.minX - previous.maxX
                if !sameLine || gap > placed.box.width * 1.5 { flush() }
            }
            let isSpace = placed.character == " "
            // A run starts and ends on real text. Only the characters inside it set the box, so a
            // trailing space cannot stretch the run past the pixels it belongs to. A space also has
            // no height, so measuring the next character against one would break every run in two.
            if text.isEmpty, isSpace { continue }
            text.append(placed.character)
            guard !isSpace else { continue }
            box = box.union(placed.box)
            previous = placed.box
        }
        flush()
        return runs
    }
}
