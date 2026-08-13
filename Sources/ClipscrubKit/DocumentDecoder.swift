import AppKit
import CoreGraphics
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// A document decoded into inputs the redaction pipeline already understands: plain text (which the
/// text pipeline tokenises) or page images (which the image pipeline OCRs → boxes → flattens).
public enum DecodedDocument: Sendable {
    case text(String)
    case images([SendableImage]) // one per PDF page, or a single raster image
}

/// Turns the file formats clinicians actually have — PDF, Office docs, HTML, structured text — into
/// `DecodedDocument`s for the existing pipeline. Native frameworks only (PDFKit + AppKit text system),
/// no third-party deps. DICOM/EDF are handled separately (structured field de-id), not here.
public enum DocumentDecoder {
    /// Rich-text formats the AppKit text system reads → we extract the plain string and redact that.
    static let richTextExtensions: Set<String> = ["rtf", "rtfd", "doc", "docx", "html", "htm", "odt", "webarchive"]

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
            return .images([SendableImage(image)])
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
            case .images(let pages):
                for (index, page) in pages.enumerated() {
                    images.append((page, pages.count > 1 ? "\(name) \(index + 1)" : name))
                }
            case nil:
                continue
            }
        }
        return (images, texts)
    }

    private static func decodePDF(_ url: URL) -> DecodedDocument? {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return nil }
        var pages: [SendableImage] = []
        for index in 0..<document.pageCount {
            // Fail CLOSED: if any page can't be rendered, refuse the whole document rather than hand
            // back a redacted PDF that silently dropped a page.
            guard let page = document.page(at: index), let image = render(page) else { return nil }
            pages.append(SendableImage(image))
        }
        return pages.isEmpty ? nil : .images(pages)
    }

    /// Render a PDF page upright at 2× so OCR has enough resolution. `thumbnail(of:for:)` handles the
    /// page's own rotation/box origin, so the result is correctly oriented for Vision.
    private static func render(_ page: PDFPage, scale: CGFloat = 2) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 1, size.height > 1 else { return nil }
        return page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
