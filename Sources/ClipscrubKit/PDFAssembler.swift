import CoreGraphics
import Foundation

/// Re-assembles redacted page images into a single **flattened** PDF (one page per image). Because
/// the pages are rasterised, there is no selectable text left under the redaction boxes — the classic
/// "box drawn over still-extractable text" leak cannot happen. Pure CoreGraphics, no PDFKit/AppKit.
public enum PDFAssembler {
    public static func pdfData(from images: [CGImage]) -> Data? {
        guard let first = images.first else { return nil }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var firstBox = CGRect(x: 0, y: 0, width: CGFloat(first.width), height: CGFloat(first.height))
        guard let context = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else { return nil }
        for image in images {
            var box = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }
}
