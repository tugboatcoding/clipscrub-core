import CoreGraphics
import ImageIO
import XCTest
@testable import ClipscrubKit

final class ImageRedactorTests: XCTestCase {
    private func solidImage(_ width: Int, _ height: Int, gray: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Production's own walker, not a second one. A test-side copy with weaker bounds reports a
    /// chunk list the shipping code would never produce.
    private func pngChunkTypes(_ png: Data) -> [String] { ImageRedactor.chunkTypes(of: png) }

    private func averageRGB(_ image: CGImage) -> (UInt8, UInt8, UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (pixel[0], pixel[1], pixel[2])
    }

    func testFullCoverDiscardsOriginalPixelsAndSensitiveMetadata() throws {
        let white = solidImage(40, 30, gray: 1.0)
        let fullCover = DetectedEntity(
            type: .face, value: "face", confidence: 1, source: .face,
            locus: .region(CGRect(x: 0, y: 0, width: 40, height: 30))
        )
        let png = try XCTUnwrap(ImageRedactor().redact(white, entities: [fullCover]))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        let (r, g, b) = averageRGB(decoded)
        XCTAssertLessThan(r, 8)
        XCTAssertLessThan(g, 8)
        XCTAssertLessThan(b, 8)

        // Tightened alongside the encoder, not to make a failing test pass. This used to excuse an
        // {Exif} dictionary holding pixel dimensions; `encodePNG` now removes the chunk carrying
        // them, so the exemption would only hide a regression.
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        XCTAssertNil(props[kCGImagePropertyExifDictionary])
        XCTAssertNil(props[kCGImagePropertyGPSDictionary])
        XCTAssertNil(props[kCGImagePropertyTIFFDictionary])
    }

    /// The API view is not the file. `CGImageSourceCopyPropertiesAtIndex` returning no {Exif} is
    /// what a reader sees; this walks the bytes, because the chunk is what actually ships.
    func testExportedPNGCarriesNoMetadataChunkOnDisk() throws {
        let png = try XCTUnwrap(ImageRedactor().encodePNG(solidImage(64, 40, gray: 0)))
        let types = pngChunkTypes(png)

        XCTAssertTrue(types.contains("IHDR"), "the export is not a PNG any more")
        XCTAssertTrue(types.contains("IDAT"), "the image data is gone")
        for carrier in ["eXIf", "tEXt", "zTXt", "iTXt"] {
            XCTAssertFalse(types.contains(carrier), "\(carrier) chunk shipped in the export")
        }
        XCTAssertNotNil(
            CGImageSourceCreateWithData(png as CFData, nil).flatMap {
                CGImageSourceCreateImageAtIndex($0, 0, nil)
            },
            "stripping the chunk left a PNG nothing can decode"
        )
    }

    /// A file the walk cannot parse yields nothing, and `encodePNG` yields nil with it.
    ///
    /// The first version of this returned the input unchanged on a parse fault, reasoning that
    /// leaving a metadata chunk in beat truncating an export. That is fail-open on a de-ID tool:
    /// the caller gets bytes that look like a clean export and are not, with nothing to check. The
    /// CLI's own rule is the opposite — on an error write nothing — so this follows it.
    func testAPNGTheWalkCannotParseYieldsNothing() throws {
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        // A chunk claiming far more payload than the data holds.
        XCTAssertNil(ImageRedactor.withoutMetadataChunks(
            signature + Data([0xFF, 0xFF, 0xFF, 0xFF]) + Data("eXIf".utf8) + Data([0x00])
        ))
        // Well-formed chunks that simply never reach IEND.
        XCTAssertNil(ImageRedactor.withoutMetadataChunks(signature))
        XCTAssertNil(ImageRedactor.withoutMetadataChunks(Data()))
        // Trailing bytes after IEND are not part of the image, and copying them out would carry
        // exactly what this function removes.
        let iend = Data([0, 0, 0, 0]) + Data("IEND".utf8) + Data([0xAE, 0x42, 0x60, 0x82])
        XCTAssertNotNil(ImageRedactor.withoutMetadataChunks(signature + iend))
        XCTAssertNil(ImageRedactor.withoutMetadataChunks(signature + iend + Data("trailing".utf8)))
    }

    /// A chunk type the allowlist has never heard of is dropped, not kept.
    ///
    /// The reason the list names what may stay: a denylist of known metadata carriers passes
    /// anything its author did not think of, which is the failure mode of every such list.
    func testAnUnknownChunkTypeIsDroppedRatherThanCarried() throws {
        let png = try XCTUnwrap(ImageRedactor().encodePNG(solidImage(16, 16, gray: 0)))
        var spiked = Data(png.prefix(8))
        let payload = Data("2026-08-22T00:00:00Z".utf8)
        var header = Data()
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { header.append(contentsOf: $0) }
        // `tIME` is real, is not on the allowlist, and is exactly the shape of thing that leaks.
        spiked += header + Data("tIME".utf8) + payload + Data([0, 0, 0, 0])
        spiked += png.dropFirst(8)

        let types = pngChunkTypes(try XCTUnwrap(ImageRedactor.withoutMetadataChunks(spiked)))
        XCTAssertFalse(types.contains("tIME"), "an unlisted chunk survived the walk")
        XCTAssertTrue(types.contains("IDAT"), "the image data was dropped with it")
    }

    func testDisabledRegionLeavesImageIntact() throws {
        let white = solidImage(20, 20, gray: 1.0)
        var entity = DetectedEntity(
            type: .face, value: "face", confidence: 1, source: .face,
            locus: .region(CGRect(x: 0, y: 0, width: 20, height: 20))
        )
        entity.isEnabled = false
        let png = try XCTUnwrap(ImageRedactor().redact(white, entities: [entity]))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let (r, _, _) = averageRGB(decoded)
        XCTAssertGreaterThan(r, 200) // still white
    }
}
