import CoreGraphics

/// Shrinks an image to a preview-sized copy.
///
/// A batch that keeps a full-resolution picture per item grows with the number of items. A 4K
/// screenshot is around 33 MB once it is a bitmap, so a folder of 200 of them is gigabytes if each
/// one is held. Keeping a small copy instead means the memory a run needs does not depend on how many
/// files are in the folder.
public enum ImageDownscaler {
    /// A copy of `image` whose longest side is at most `maxDimension`, keeping the aspect ratio.
    ///
    /// Returns the image unchanged when it already fits, so a small icon is not re-drawn for nothing.
    /// Returns nil when the bitmap cannot be created.
    public static func thumbnail(of image: CGImage, maxDimension: Int = 512) -> CGImage? {
        guard maxDimension > 0, image.width > 0, image.height > 0 else { return nil }
        let longest = max(image.width, image.height)
        guard longest > maxDimension else { return image }

        let scale = Double(maxDimension) / Double(longest)
        // At least one pixel each way. A 4000x3 banner scaled to 512 rounds its short side to zero,
        // and CGContext refuses a zero-sized bitmap.
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))

        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
