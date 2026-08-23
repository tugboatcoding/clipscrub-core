import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// How a detected region is obscured. Solid is the safe default; blur/pixelate are offered but
/// can be partially reversible on some content, so they are opt-in.
public enum RedactionStyle: String, Sendable, CaseIterable, Hashable, Codable {
    case solid
    case gradient
    case blur
    case pixelate

    public var label: String {
        switch self {
        case .solid: "Colored box"
        case .gradient: "Gradient"
        case .blur: "Blur"
        case .pixelate: "Pixelate"
        }
    }

    /// Blur and pixelate only partially obscure and can be partially reversible. Solid and gradient
    /// fully cover the region (original pixels discarded), so they are safe.
    public var isReversible: Bool { self == .blur || self == .pixelate }
}

/// Permanently removes pixels under detected regions.
///
/// Draws opaque blocks over each enabled `.region` entity, **flattens to a new bitmap**, and
/// re-encodes as PNG with **all metadata stripped**. Covered pixels are truly discarded — the
/// export contains no original pixels, alpha, or EXIF/GPS. This is a raster operation, never a
/// movable overlay.
public struct ImageRedactor: Sendable {
    public init() {}

    /// Flatten opaque blocks over enabled `.region` entities into a **new** bitmap (original
    /// pixels discarded). Region loci are pixel space, top-left origin (flipped to CoreGraphics'
    /// bottom-left space when filling).
    public func flattened(
        _ image: CGImage,
        entities: [DetectedEntity],
        style: RedactionStyle = .solid,
        fill: CGColor? = nil,
        gradientColors: (RGBA, RGBA)? = nil,
        tokens: [DetectedEntity.ID: String]? = nil
    ) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Region loci are top-left origin; flip to CoreGraphics bottom-left. Grow each block by a
        // couple of pixels all round so it fully covers the text/photo/barcode with no leftover
        // border, clamped to the image bounds.
        let bleed: CGFloat = 2
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let regions = entities.filter(\.isEnabled).compactMap { entity -> (id: DetectedEntity.ID, rect: CGRect)? in
            guard case let .region(rect) = entity.locus else { return nil }
            let flipped = CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)
            return (entity.id, flipped.insetBy(dx: -bleed, dy: -bleed).intersection(bounds))
        }
        guard !regions.isEmpty else { return context.makeImage() }

        switch style {
        case .solid:
            context.setFillColor(fill ?? CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            regions.forEach { context.fill($0.rect) }
        case .gradient:
            let space = CGColorSpaceCreateDeviceRGB()
            let stops = gradientColors ?? (RGBA(0.58, 0.58, 0.61), RGBA(0.88, 0.88, 0.91))
            let gradient = CGGradient(colorsSpace: space,
                                      colors: [stops.0.cgColor, stops.1.cgColor] as CFArray,
                                      locations: [0, 1])
            for region in regions {
                context.saveGState()
                context.addRect(region.rect)
                context.clip()
                if let gradient {
                    context.drawLinearGradient(gradient, start: CGPoint(x: region.rect.minX, y: region.rect.minY),
                                               end: CGPoint(x: region.rect.maxX, y: region.rect.maxY), options: [])
                } else {
                    context.setFillColor(CGColor(gray: 0.3, alpha: 1))
                    context.fill(region.rect)
                }
                context.restoreGState()
            }
        case .blur, .pixelate:
            let ciContext = CIContext()
            let filtered = Self.filter(CIImage(cgImage: image).clampedToExtent(), style: style,
                                       minDimension: Double(min(width, height)))
            for region in regions {
                if let filtered, let filteredRegion = ciContext.createCGImage(filtered, from: region.rect) {
                    context.draw(filteredRegion, in: region.rect)
                } else {
                    // Fail closed: filter failure or an uncreatable region → solid black, NEVER the
                    // source pixels (a nil filter must not fall back to the un-blurred original).
                    context.setFillColor(CGColor(gray: 0, alpha: 1))
                    context.fill(region.rect)
                }
            }
        }

        // Pseudonymise: repaint each fully-covered box white and stamp the stable token in black
        // (solid/gradient only — blur/pixelate don't fully cover, so no token).
        if let tokens, !style.isReversible {
            for region in regions {
                if let token = tokens[region.id] {
                    context.setFillColor(CGColor(gray: 0.97, alpha: 1))
                    context.fill(region.rect)
                    Self.draw(token: token, in: region.rect, context: context)
                }
            }
        }

        return context.makeImage()
    }

    private static func draw(token: String, in rect: CGRect, context: CGContext) {
        let fontSize = max(7, min(rect.height * 0.5, 30))
        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        let attributes = [kCTFontAttributeName: font,
                          kCTForegroundColorAttributeName: CGColor(gray: 0.08, alpha: 1)] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, token as CFString, attributes) else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])
        guard bounds.width <= rect.width * 0.95 else { return } // don't overflow the box
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: rect.midX - bounds.width / 2,
                                       y: rect.midY - bounds.height / 2 - bounds.origin.y)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Returns nil if the filter produces no output — the caller then fails closed (black), rather
    /// than fall back to the un-obscured original image.
    private static func filter(_ image: CIImage, style: RedactionStyle, minDimension: Double) -> CIImage? {
        switch style {
        case .blur:
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = image
            filter.radius = Float(max(6, minDimension * 0.03))
            return filter.outputImage
        case .pixelate:
            let filter = CIFilter.pixellate()
            filter.inputImage = image
            filter.scale = Float(max(8, minDimension * 0.035))
            return filter.outputImage
        case .solid, .gradient:
            return image
        }
    }

    /// - Returns: PNG data with no metadata, or nil if the graphics context can't be built.
    public func redact(_ image: CGImage, entities: [DetectedEntity], fill: CGColor? = nil) -> Data? {
        guard let flat = flattened(image, entities: entities, fill: fill) else { return nil }
        return encodePNG(flat)
    }

    /// Encode a CGImage as PNG carrying no metadata at all, or nil.
    ///
    /// Passing no properties is not enough. ImageIO writes an `eXIf` chunk regardless — measured at
    /// 56 bytes holding PixelXDimension and PixelYDimension — and neither a null nor an empty Exif
    /// dictionary suppresses it: the first fails the finalize outright, the second is ignored. Those
    /// two values identify nobody, so the chunk is harmless in itself. It is removed anyway, because
    /// "no metadata" is what a de-identification tool should be able to say without a footnote, and
    /// a metadata block that exists is one a later encoder change can fill.
    ///
    /// A file the chunk walk cannot parse returns nil rather than the unstripped bytes. Handing back
    /// an export whose contents are not known is the one outcome this function exists to prevent.
    public func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Self.withoutMetadataChunks(data as Data)
    }

    /// Keep the chunks a PNG needs to render, and drop everything else.
    ///
    /// An allowlist, not a list of metadata carriers to remove. A denylist is only as good as the
    /// author's memory of the format: `eXIf` is what ImageIO writes here, but `tIME` and the text
    /// chunks would ride out just as quietly, and the next chunk type nobody thought of rides out
    /// too. Naming what may stay makes the unknown case default to removal.
    ///
    /// `iCCP`, `sRGB`, `gAMA`, `cHRM`, `sBIT` and `tRNS` are here because dropping them changes how
    /// the image renders — colour is not metadata. `pHYs` and `tIME` are not: a print size and a
    /// timestamp are facts about the original, and this file is meant to carry none.
    ///
    /// Returns nil when the walk cannot reach a well-formed `IEND`. That is the same fail-closed
    /// rule the CLI states: on an error, write nothing rather than hand back something whose
    /// contents are not known. The input here is ImageIO's own output moments earlier, so an
    /// unparseable one means something is wrong that a caller should not paper over.
    public static let renderingChunkTypes: Set<String> = [
        "IHDR", "PLTE", "IDAT", "IEND", "iCCP", "sRGB", "gAMA", "cHRM", "sBIT", "tRNS",
    ]

    static func withoutMetadataChunks(_ png: Data) -> Data? {
        let signature = 8
        let keep = renderingChunkTypes
        guard png.count > signature else { return nil }
        let bytes = [UInt8](png)

        var kept = Data(bytes[0..<signature])
        var cursor = signature
        while cursor + 8 <= bytes.count {
            let length = bytes[cursor..<cursor + 4].reduce(0) { Int($0) << 8 | Int($1) }
            guard let type = String(bytes: bytes[cursor + 4..<cursor + 8], encoding: .ascii)
            else { return nil }
            // 4 length + 4 type + payload + 4 CRC. `length` comes from the file, so the add is
            // checked before it is used as an index.
            let (next, overflowed) = cursor.addingReportingOverflow(12 + length)
            guard !overflowed, next <= bytes.count else { return nil }
            if keep.contains(type) { kept.append(contentsOf: bytes[cursor..<next]) }
            cursor = next
            // IEND ends the image, and it carries no payload. Bytes after it are not part of the
            // PNG — dropping them quietly would hand back a file the caller never described, so an
            // export that has any is refused like every other thing the walk cannot account for.
            if type == "IEND" { return (length == 0 && next == bytes.count) ? kept : nil }
        }
        return nil
    }

    /// The chunk types a PNG carries, in file order. Empty when the walk cannot parse the file.
    ///
    /// Shared with the verify harness and the tests on purpose: a second walker written beside this
    /// one drifts, and a checker with weaker bounds than the thing it checks reports what it wishes
    /// were true.
    public static func chunkTypes(of png: Data) -> [String] {
        let signature = 8
        guard png.count > signature else { return [] }
        let bytes = [UInt8](png)
        var types: [String] = []
        var cursor = signature
        while cursor + 8 <= bytes.count {
            let length = bytes[cursor..<cursor + 4].reduce(0) { Int($0) << 8 | Int($1) }
            guard let type = String(bytes: bytes[cursor + 4..<cursor + 8], encoding: .ascii)
            else { return types }
            let (next, overflowed) = cursor.addingReportingOverflow(12 + length)
            guard !overflowed, next <= bytes.count else { return types }
            types.append(type)
            cursor = next
            if type == "IEND" { break }
        }
        return types
    }
}
