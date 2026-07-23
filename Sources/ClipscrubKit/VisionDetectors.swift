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
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        return (request.results ?? []).map { face in
            DetectedEntity(
                type: .face,
                value: "face",
                confidence: Double(face.confidence),
                source: .face,
                locus: .region(Self.pixelRect(face.boundingBox, width, height))
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
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        return (request.results ?? []).map { barcode in
            DetectedEntity(
                type: .other("BARCODE"),
                value: "barcode",
                confidence: Double(barcode.confidence),
                source: .vision,
                locus: .region(VisionFaceDetector.pixelRect(barcode.boundingBox, width, height))
            )
        }
    }
}

/// Runs on-device OCR and returns recognised text with per-observation boxes (pixel space,
/// top-left origin). PHI detection then runs over the text; matched spans map back to boxes.
public struct VisionTextRecognizer: Sendable {
    public init() {}

    public func recognize(_ image: CGImage) throws -> [OCRObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRObservation(
                text: candidate.string,
                box: VisionFaceDetector.pixelRect(observation.boundingBox, width, height)
            )
        }
    }
}
