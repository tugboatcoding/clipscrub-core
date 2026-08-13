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

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let sensitiveExif = exif.keys.contains {
            $0 != kCGImagePropertyExifPixelXDimension && $0 != kCGImagePropertyExifPixelYDimension
        }
        XCTAssertNil(props[kCGImagePropertyGPSDictionary])
        XCTAssertNil(props[kCGImagePropertyTIFFDictionary])
        XCTAssertFalse(sensitiveExif)
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
