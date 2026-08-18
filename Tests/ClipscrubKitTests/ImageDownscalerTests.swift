import CoreGraphics
import XCTest
@testable import ClipscrubKit

final class ImageDownscalerTests: XCTestCase {
    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    func testLongestSideIsCappedAndAspectRatioSurvives() throws {
        let source = try image(width: 4000, height: 2000)

        let thumbnail = try XCTUnwrap(ImageDownscaler.thumbnail(of: source, maxDimension: 512))

        XCTAssertEqual(thumbnail.width, 512)
        XCTAssertEqual(thumbnail.height, 256)
    }

    func testTallImagesAreCappedOnTheirOwnLongSide() throws {
        let source = try image(width: 600, height: 3000)

        let thumbnail = try XCTUnwrap(ImageDownscaler.thumbnail(of: source, maxDimension: 512))

        XCTAssertEqual(thumbnail.height, 512)
        XCTAssertEqual(thumbnail.width, 102)
    }

    func testASmallImageComesBackUntouched() throws {
        let source = try image(width: 300, height: 200)

        let thumbnail = try XCTUnwrap(ImageDownscaler.thumbnail(of: source, maxDimension: 512))

        XCTAssertEqual(thumbnail.width, 300)
        XCTAssertEqual(thumbnail.height, 200)
    }

    func testAnExtremeRatioKeepsAtLeastOnePixel() throws {
        // 4000x3 scaled to 512 rounds the short side to zero, and CGContext refuses a zero-sized
        // bitmap. Left unguarded this returns nil and the history row loses its preview.
        let source = try image(width: 4000, height: 3)

        let thumbnail = try XCTUnwrap(ImageDownscaler.thumbnail(of: source, maxDimension: 512))

        XCTAssertEqual(thumbnail.width, 512)
        XCTAssertEqual(thumbnail.height, 1)
    }
}
