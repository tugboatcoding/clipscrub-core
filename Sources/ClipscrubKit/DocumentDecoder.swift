import AppKit
import CoreGraphics
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// One page ready for the image pipeline: the pixels to OCR and redact, plus the page's own text
/// when it had any. A PNG has pixels and no text. A scanned PDF page is the same case.
public struct DecodedPage: Sendable {
    public let image: SendableImage
    /// The page's characters and their boxes, used to keep the redacted export searchable. Nil for
    /// a raster image or a scanned page, which then exports as pixels only.
    public let text: PDFPageText?
    /// The page's size in points, for a page that came from a PDF. A raster image has no size in
    /// points, so it is emitted at its pixel count and this stays nil.
    public let pageSize: CGSize?

    public init(image: SendableImage, text: PDFPageText? = nil, pageSize: CGSize? = nil) {
        self.image = image
        self.text = text
        self.pageSize = pageSize
    }
}

/// A document decoded into inputs the redaction pipeline already understands: plain text (which the
/// text pipeline tokenises) or pages (which the image pipeline OCRs → boxes → flattens).
public enum DecodedDocument: Sendable {
    case text(String)
    case pages([DecodedPage]) // one per PDF page, or a single raster image
}

/// Turns the file formats clinicians actually have — PDF, Office docs, HTML, structured text — into
/// `DecodedDocument`s for the existing pipeline. Native frameworks only (PDFKit + AppKit text system),
/// no third-party deps. DICOM/EDF are handled separately (structured field de-id), not here.
public enum DocumentDecoder {
    /// Rich-text formats the AppKit text system reads → we extract the plain string and redact that.
    public static let richTextExtensions: Set<String> = ["rtf", "rtfd", "doc", "docx", "html", "htm", "odt", "webarchive"]

    /// Structured and plain text formats worth reading when nobody named the file.
    ///
    /// `decode`'s last branch is more generous than this: it reads any file that turns out to be
    /// valid UTF-8. That is right for a file somebody picked by hand and wrong for a sweep of a
    /// folder, which would otherwise open every `.swift` source file and build log it walked past.
    public static let plainTextExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "json", "ndjson", "xml", "csv", "tsv", "hl7", "yaml", "yml",
    ]

    /// Whether a folder sweep should hand this file to `decode`.
    ///
    /// Built from the same branches `decode` takes — PDF, the rich text formats, anything the system
    /// calls an image, and the text formats above. Adding a format means adding it in one place.
    public static func supports(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if ext == "pdf" || richTextExtensions.contains(ext) || plainTextExtensions.contains(ext) { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .image) ?? false
    }

    public static func decode(_ url: URL) -> DecodedDocument? {
        let ext = url.pathExtension.lowercased()

        if ext == "pdf" { return decodePDF(url) }

        if richTextExtensions.contains(ext) {
            if let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil),
               !attributed.string.isEmpty {
                return .text(attributed.string)
            }
            return nil
        }

        // Raster image.
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image),
           let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return .pages([DecodedPage(image: SendableImage(image))])
        }

        // Plain / structured text (txt, md, json, xml, csv, tsv, hl7, log, …).
        if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return .text(text)
        }
        return nil
    }

    /// Decode a batch of files into pipeline-ready inputs. Runs the (possibly slow) file reads on the
    /// caller's thread; the returned types are `Sendable` so the caller builds any `NSImage` on the
    /// main actor. Multi-page docs get `<name> N` page names.
    public static func route(_ urls: [URL])
        -> (images: [(image: SendableImage, name: String)], texts: [(text: String, name: String)]) {
        var images: [(SendableImage, String)] = []
        var texts: [(String, String)] = []
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            switch decode(url) {
            case .text(let text):
                texts.append((text, name))
            case .pages(let pages):
                for (index, page) in pages.enumerated() {
                    images.append((page.image, pages.count > 1 ? "\(name) \(index + 1)" : name))
                }
            case nil:
                continue
            }
        }
        return (images, texts)
    }

    private static func decodePDF(_ url: URL) -> DecodedDocument? {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return nil }
        var pages: [DecodedPage] = []
        for index in 0..<document.pageCount {
            // Fail CLOSED: if any page can't be rendered, refuse the whole document rather than hand
            // back a redacted PDF that silently dropped a page.
            guard let page = document.page(at: index), let image = render(page) else { return nil }
            pages.append(DecodedPage(image: SendableImage(image),
                                     text: PDFPageText.extract(from: page),
                                     pageSize: uprightSize(of: page)))
        }
        return pages.isEmpty ? nil : .pages(pages)
    }

    /// Render a PDF page upright at 2× so OCR has enough resolution. `thumbnail(of:for:)` handles the
    /// page's own rotation/box origin, so the result is correctly oriented for Vision.
    ///
    /// The requested size is the page size AFTER rotation. `thumbnail` fits inside what it is asked
    /// for, so asking with the unrotated aspect made a landscape page come back at 1.5× instead of
    /// 2× — less resolution for OCR than intended, on the pages that need it most.
    private static func render(_ page: PDFPage, scale: CGFloat = 2) -> CGImage? {
        let upright = uprightSize(of: page)
        let size = CGSize(width: upright.width * scale, height: upright.height * scale)
        guard size.width > 1, size.height > 1 else { return nil }
        return page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The page's size in points after its own rotation is applied, which is what a reader sees.
    private static func uprightSize(of page: PDFPage) -> CGSize {
        let bounds = page.bounds(for: .mediaBox)
        let turned = ((page.rotation % 360) + 360) % 360 % 180 != 0
        return CGSize(width: turned ? bounds.height : bounds.width,
                      height: turned ? bounds.width : bounds.height)
    }
}
