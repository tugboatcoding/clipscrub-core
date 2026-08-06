import CoreGraphics
import Foundation
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
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = VisionFaceDetector.pixelRect(observation.boundingBox, width, height)
            return OCRObservation(text: candidate.string, box: tile?.inSource(box) ?? box)
        }
    }
}
