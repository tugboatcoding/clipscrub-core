import CoreGraphics
import Foundation

/// A crop Core Graphics refused. Cutting the image up is part of reading it, so this stops the scan
/// instead of quietly leaving that part of the picture unread and reporting success.
public struct TileCropFailed: Error {
    public let rect: CGRect
    public init(rect: CGRect) { self.rect = rect }
}

/// Splits an image into overlapping pieces so Vision sees content at close to its captured size.
///
/// Vision reads an image at a fixed working size. A scrolling capture is one tall stitched image, so
/// the whole thing gets shrunk to fit and the rows inside it shrink with it. Text recognition on a
/// 1600x15360 capture returns **nothing at all** — and a scan that reads nothing redacts nothing, so
/// the names and dates in it survive into the exported picture. Cutting the image into pieces first
/// keeps every row near the size it was captured at.
public enum ImageTiling {
    /// Strip height for text. 2048 px is about a screen-sized grab, and the overlap is taller than a
    /// line of text so a line cut by one strip edge is whole in its neighbour. Both are pixels.
    public static let textStripHeight = 2048
    public static let textStripOverlap = 384

    /// Faces are found relative to the image, not in pixels: a 40 pt chat avatar is below the floor
    /// even in a plain screen grab, and only shows up once the piece around it is small. 640 px
    /// squares put an avatar back above that floor. Both are pixels.
    public static let faceTileSide = 640
    public static let faceTileOverlap = 160

    /// How much longer than its short side a piece may run. Measured: a 4:1 piece reads in full, an
    /// 8:1 one reads nothing, so pieces are cut to stay well clear of that.
    static let maximumTileAspect = 4

    /// A piece is never cut below this, so a narrow capture is not shredded into hundreds of tiles.
    static let minimumTileSide = 512

    /// A piece of a source image plus where it sits. Only `strips` and `grid` make one, so a tile
    /// always travels with the image it was cut from.
    public struct Tile: Sendable {
        public let image: SendableImage
        /// Top-left of this tile inside the source image, in pixels.
        public let origin: CGPoint

        init(image: CGImage, origin: CGPoint) {
            self.image = SendableImage(image)
            self.origin = origin
        }

        /// A rect found inside this tile, moved into source-image pixels. Skip this and a redaction
        /// lands near the top of the image instead of on the content it was meant to cover.
        public func inSource(_ rect: CGRect) -> CGRect {
            rect.offsetBy(dx: origin.x, dy: origin.y)
        }
    }

    /// Horizontal strips, top to bottom, for text and barcodes. A capture much wider than it is tall
    /// runs into the same wall sideways, so that one is cut into columns too. One tile back means no
    /// split was needed.
    public static func strips(
        of image: CGImage, height: Int = textStripHeight, overlap: Int = textStripOverlap
    ) throws -> [Tile] {
        let width = image.width > image.height * maximumTileAspect
            ? fitted(image.width, across: image.height, limit: height)
            : image.width
        return try tiles(of: image,
                         width: width,
                         height: fitted(image.height, across: image.width, limit: height),
                         overlap: overlap)
    }

    /// Overlapping squares across the whole image, row by row.
    public static func grid(
        of image: CGImage, side: Int = faceTileSide, overlap: Int = faceTileOverlap
    ) throws -> [Tile] {
        try tiles(of: image, width: side, height: side, overlap: overlap)
    }

    private static func tiles(of image: CGImage, width: Int, height: Int, overlap: Int) throws -> [Tile] {
        try starts(total: image.height, size: height, overlap: overlap).flatMap { top in
            try starts(total: image.width, size: width, overlap: overlap).map { left in
                let rect = CGRect(x: left, y: top,
                                  width: min(width, image.width - left),
                                  height: min(height, image.height - top))
                guard let cropped = image.cropping(to: rect) else { throw TileCropFailed(rect: rect) }
                return Tile(image: cropped, origin: CGPoint(x: left, y: top))
            }
        }
    }

    /// How long a piece may run across a side of `other`, under the caller's own limit.
    private static func fitted(_ length: Int, across other: Int, limit: Int) -> Int {
        min(length, max(minimumTileSide, min(limit, other * maximumTileAspect)))
    }

    /// Tile start offsets along one axis. Evenly spaced so the last tile ends flush with the far edge
    /// and no gap is left uncovered. Spacing never exceeds `size - overlap`, so the requested overlap
    /// is a floor. Overlap counts for at most half a tile, so no request can ask for thousands of
    /// pieces. Always returns at least one offset.
    package static func starts(total: Int, size: Int, overlap: Int) -> [Int] {
        guard total > size, size > 0 else { return [0] }
        let step = max(1, size - min(max(0, overlap), size / 2))
        let gaps = Int((Double(total - size) / Double(step)).rounded(.up))
        let spacing = Double(total - size) / Double(gaps)
        return (0...gaps).map { Int((Double($0) * spacing).rounded()) }
    }

    /// The same thing found in two neighbouring tiles, measured against the smaller box so a partial
    /// read sitting inside a full one counts as a repeat.
    static func isRepeat(_ one: CGRect, _ other: CGRect, minimumOverlap: CGFloat = 0.5) -> Bool {
        let shared = one.intersection(other)
        guard !shared.isNull, !shared.isEmpty else { return false }
        let smaller = min(one.width * one.height, other.width * other.height)
        guard smaller > 0 else { return false }
        return (shared.width * shared.height) / smaller >= minimumOverlap
    }

    /// Collapse regions of one type that the tiles found more than once. The kept box grows to cover
    /// every repeat — a repeat can reach past the box that swallowed it, and those pixels were
    /// flagged too. Entities that are not regions pass through untouched.
    public static func dedupedRegions(_ entities: [DetectedEntity]) -> [DetectedEntity] {
        var kept: [DetectedEntity] = []
        for entity in entities.sorted(by: { area(of: $0) > area(of: $1) }) {
            guard case let .region(box) = entity.locus else {
                kept.append(entity)
                continue
            }
            let match = kept.firstIndex { other in
                guard case let .region(keptBox) = other.locus else { return false }
                return other.type == entity.type && isRepeat(keptBox, box)
            }
            guard let match, case let .region(keptBox) = kept[match].locus else {
                kept.append(entity)
                continue
            }
            kept[match].locus = .region(keptBox.union(box))
        }
        return kept
    }

    /// Collapse OCR lines read twice in a strip overlap. Keeps the longest reading, since a line cut
    /// by a strip edge reads short in one strip and whole in the other, and widens its box to cover
    /// both so the redaction can never land short of what was read.
    ///
    /// One reading has to contain the other before they collapse. Sharing space is not evidence of
    /// saying the same thing — a short "MRN 88213" sits inside the wide line around it, and merging
    /// on position alone would delete that text before any detector reads it.
    public static func dedupedObservations(_ observations: [OCRObservation]) -> [OCRObservation] {
        var kept: [OCRObservation] = []
        for observation in observations {
            let index = kept.firstIndex {
                isRepeat($0.box, observation.box)
                    && ($0.text.contains(observation.text) || observation.text.contains($0.text))
            }
            guard let index else {
                kept.append(observation)
                continue
            }
            let winner = observation.text.count > kept[index].text.count ? observation : kept[index]
            kept[index] = OCRObservation(text: winner.text, box: kept[index].box.union(observation.box))
        }
        return kept
    }

    private static func area(of entity: DetectedEntity) -> CGFloat {
        guard case let .region(box) = entity.locus else { return 0 }
        return box.width * box.height
    }
}
