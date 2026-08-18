import CoreGraphics
import Foundation
import os
import Vision

/// Detects faces as redaction targets (HIPAA full-face photographic images). Emits `.region`
/// entities in pixel space, top-left origin.
public struct VisionFaceDetector: EntityDetector {
    public let source: DetectionSource = .face

    public init() {}

    public func detect(in input: DetectionInput) async throws -> [DetectedEntity] {
        guard case let .image(wrapper, _) = input else { return [] }
        let image = wrapper.cgImage
        // Whole image first — that finds the big faces. Vision only finds a face that is a decent
        // fraction of what it is looking at, so a chat avatar in a screenshot is invisible to that
        // pass. The grid looks again at each small square, where the same avatar is large.
        var found = try faces(in: image, tile: nil)
        let tiles = try ImageTiling.grid(of: image)
        if tiles.count > 1 {
            for tile in tiles { found += try faces(in: tile.image.cgImage, tile: tile) }
        }
        return ImageTiling.dedupedRegions(found)
    }

    private func faces(in image: CGImage, tile: ImageTiling.Tile?) throws -> [DetectedEntity] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        return (request.results ?? []).map { face in
            let box = Self.pixelRect(face.boundingBox, width, height)
            return DetectedEntity(
                type: .face,
                value: "face",
                confidence: Double(face.confidence),
                source: .face,
                locus: .region(tile?.inSource(box) ?? box)
            )
        }
    }

    /// Vision boxes are normalized, origin bottom-left → convert to pixel space, top-left origin.
    static func pixelRect(_ box: CGRect, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(
            x: box.minX * width,
            y: (1 - box.maxY) * height,
            width: box.width * width,
            height: box.height * height
        )
    }
}

/// Detects barcodes and QR codes as redaction targets — they can encode names, MRNs, or account
/// numbers that OCR/NER never see. Emits `.region` entities in pixel space, top-left origin.
public struct VisionBarcodeDetector: EntityDetector {
    public let source: DetectionSource = .vision

    public init() {}

    public func detect(in input: DetectionInput) async throws -> [DetectedEntity] {
        guard case let .image(wrapper, _) = input else { return [] }
        let image = wrapper.cgImage
        let tiles = try ImageTiling.strips(of: image)
        guard tiles.count > 1 else { return try barcodes(in: image, tile: nil) }
        var found: [DetectedEntity] = []
        for tile in tiles { found += try barcodes(in: tile.image.cgImage, tile: tile) }
        return ImageTiling.dedupedRegions(found)
    }

    private func barcodes(in image: CGImage, tile: ImageTiling.Tile?) throws -> [DetectedEntity] {
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        return (request.results ?? []).map { barcode in
            let box = VisionFaceDetector.pixelRect(barcode.boundingBox, width, height)
            return DetectedEntity(
                type: .other("BARCODE"),
                value: "barcode",
                confidence: Double(barcode.confidence),
                source: .vision,
                locus: .region(tile?.inSource(box) ?? box)
            )
        }
    }
}

/// Runs on-device OCR and returns recognised text with per-observation boxes (pixel space,
/// top-left origin). PHI detection then runs over the text; matched spans map back to boxes.
public struct VisionTextRecognizer: Sendable {
    public init() {}

    /// The languages OCR reads text in, ranked by preference — intersected at runtime with what
    /// this OS build's Vision revision actually supports (`recognitionLanguages` below).
    ///
    /// Covers the scripts `given-names.json` carries native forms for (ja/zh-Hans/ar/es) plus the
    /// two English locales, so language-independent rules (email, IP, JWT, SSN-format, dotted
    /// ICD-10, domain) and user rules read non-English screenshots too. English-label-keyed rules
    /// stay English-only — matching a language does not translate a label.
    ///
    /// **What this list does NOT cover, and why:**
    /// - **zh-Hant (Traditional Chinese) is deliberately absent**, even though this OS supports it
    ///   — `given-names.json`'s zh entries are Simplified only, and shipping OCR support with no
    ///   matching gazetteer entries is a silent coverage gap rather than a correctness bug. Add
    ///   zh-Hant back only alongside Traditional given names.
    /// - **hi (Hindi) has no native-script entries in `given-names.json`** — only romanized ones
    ///   — so Devanagari-script names are unreachable by the name gazetteer even though hi-IN OCR
    ///   is requested. Kept in the preferred list because the language-independent rules still
    ///   benefit; the gazetteer gap is a follow-up, not blocking.
    /// - **en-GB is requested but not supported on the OS this was measured against** (macOS 26,
    ///   Vision only advertises `en-US` for English) — harmless to request; `resolve` drops
    ///   whatever the OS doesn't support.
    /// - **Vietnamese is not requested at all.** An earlier draft of this file asked for `vi-VN`,
    ///   which was already inert — Vision's actual identifier is `vi-VT`, so that request matched
    ///   nothing and silently read no Vietnamese. Left out here rather than added back as `vi-VT`
    ///   sight-unseen: no given-names entries and no fixture exist to verify it.
    /// - **Multi-character CJK names only match as isolated tokens.** `CommonNameDetector`'s word
    ///   regex uses `\b`, and ICU's `\b` does not segment CJK text into words — a name embedded in
    ///   running Japanese/Chinese prose (山田大翔さんの記録) reads as one long token and won't hit
    ///   the gazetteer. A name alone in a table cell or form field (the common screenshot shape)
    ///   still matches.
    ///
    /// Measured on macOS 26 (`VNRecognizeTextRequest.supportedRecognitionLanguages()`, `.accurate`
    /// level): the OS supports en-US, es-ES, ja-JP, zh-Hans, zh-Hant, ar-SA (not en-GB, not
    /// hi-IN) — so `recognitionLanguages` below resolves to en-US, es-ES, ja-JP, zh-Hans, ar-SA on
    /// that OS. An unsupported preferred language is silently absent from the OS's list, not
    /// thrown — `resolve` never sees an error for that case, only for the probe call itself.
    public static let preferredRecognitionLanguages = [
        "en-US", "en-GB", "es-ES", "ja-JP", "zh-Hans", "ar-SA", "hi-IN",
    ]

    /// Pure: preferred languages intersected with what the OS supports, preferred's order kept.
    /// Falls back to English-only when the intersection is empty (including "nothing preferred is
    /// supported"). Split out from `recognitionLanguages` so this decision is unit-testable without
    /// a live Vision probe.
    static func resolve(preferred: [String], supported: Set<String>) -> [String] {
        let matched = preferred.filter { supported.contains($0) }
        return matched.isEmpty ? ["en-US"] : matched
    }

    private static let logger = Logger(subsystem: "com.tugboat.clipscrub", category: "VisionTextRecognizer")

    /// The resolved language list actually handed to Vision. A redaction app degrading to
    /// English-only is a silent product regression, not a cosmetic detail, so both ways this can
    /// happen are logged rather than swallowed: the support probe throwing, and the probe
    /// succeeding but returning a set that shares nothing with `preferredRecognitionLanguages`.
    public static let recognitionLanguages: [String] = {
        let probe = VNRecognizeTextRequest()
        probe.recognitionLevel = .accurate
        let supported: [String]
        do {
            supported = try probe.supportedRecognitionLanguages()
        } catch {
            logger.fault(
                "supportedRecognitionLanguages() threw \(String(describing: error), privacy: .public) — OCR degraded to English-only (en-US) for this process"
            )
            return ["en-US"]
        }
        let supportedSet = Set(supported)
        let matched = preferredRecognitionLanguages.filter { supportedSet.contains($0) }
        let dropped = preferredRecognitionLanguages.filter { !supportedSet.contains($0) }
        if !dropped.isEmpty {
            logger.notice(
                "this OS does not support \(dropped.joined(separator: ", "), privacy: .public) from the preferred OCR language list — reading the rest"
            )
        }
        guard !matched.isEmpty else {
            logger.fault(
                "none of \(preferredRecognitionLanguages.joined(separator: ", "), privacy: .public) are supported on this OS — OCR degraded to English-only (en-US) for this process"
            )
            return ["en-US"]
        }
        return matched
    }()

    public func recognize(_ image: CGImage) throws -> [OCRObservation] {
        let tiles = try ImageTiling.strips(of: image)
        guard tiles.count > 1 else { return try recognize(image, tile: nil) }
        // Tiles come back row by row, so reading them in order keeps the page's reading order —
        // which is what the detectors then run over as one string.
        var observations: [OCRObservation] = []
        for tile in tiles { observations += try recognize(tile.image.cgImage, tile: tile) }
        return ImageTiling.dedupedObservations(observations)
    }

    private func recognize(_ image: CGImage, tile: ImageTiling.Tile?) throws -> [OCRObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Off: nearly everything here is an identifier, and correction pulls a read towards real
        // words. A record number bent into a word no longer matches the rule that would have caught
        // it, so it stays in the picture. Prose reads a little better with it on, but that is not
        // what this pass is for.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = Self.recognitionLanguages
        // Deployment target is macOS 15 (Package.swift), well past the macOS 13 / revision-3 floor
        // this needs, so no @available fallback is required here.
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        return (request.results ?? []).compactMap { observation -> OCRObservation? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = VisionFaceDetector.pixelRect(observation.boundingBox, width, height)
            return OCRObservation(
                text: candidate.string,
                box: tile?.inSource(box) ?? box,
                wordBoxes: Self.wordBoxes(of: candidate, width, height, tile: tile)
            )
        }
    }

    /// Asks Vision where each word of a recognised line sits. Vision hands back one box per line, so
    /// without this a span anywhere on a line can only be covered by blacking out the whole line.
    ///
    /// All words or none. Dropping just the word Vision could not place would leave a hole at the
    /// edge of a span: an identifier spanning two words, with the second one missing, would be
    /// covered up to the gap and readable after it. Returning nothing instead sends the caller back
    /// to the line box, which covers everything the line holds.
    private static func wordBoxes(
        of candidate: VNRecognizedText, _ width: CGFloat, _ height: CGFloat, tile: ImageTiling.Tile?
    ) -> [OCRObservation.WordBox] {
        let string = candidate.string
        var boxes: [OCRObservation.WordBox] = []
        for range in string.whitespaceSeparatedWordRanges() {
            guard let rectangle = try? candidate.boundingBox(for: range) else { return [] }
            let pixels = VisionFaceDetector.pixelRect(rectangle.boundingBox, width, height)
            boxes.append(OCRObservation.WordBox(
                range: string.distance(from: string.startIndex, to: range.lowerBound)
                    ..< string.distance(from: string.startIndex, to: range.upperBound),
                box: tile?.inSource(pixels) ?? pixels
            ))
        }
        return boxes
    }
}

private extension String {
    /// Ranges of the runs of non-whitespace in this string.
    func whitespaceSeparatedWordRanges() -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var wordStart: String.Index?
        for index in indices {
            if self[index].isWhitespace {
                if let start = wordStart { ranges.append(start..<index) }
                wordStart = nil
            } else if wordStart == nil {
                wordStart = index
            }
        }
        if let start = wordStart { ranges.append(start..<endIndex) }
        return ranges
    }
}
