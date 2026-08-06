import CoreGraphics
import Foundation

/// Lays out OCR observations into one searchable string, tracking each observation's character
/// range so a PHI span detected in the text can be mapped back to the pixel box(es) that carry it.
public struct OCRLayout: Sendable {
    public let text: String
    private let spans: [(start: Int, end: Int, box: CGRect)]

    public init(observations: [OCRObservation], separator: String = "\n") {
        var joined = ""
        var spans: [(Int, Int, CGRect)] = []
        for (index, observation) in observations.enumerated() {
            if index > 0 { joined += separator }
            let start = joined.count
            joined += observation.text
            spans.append((start, joined.count, observation.box))
        }
        self.text = joined
        self.spans = spans
    }

    /// Boxes whose OCR text overlaps the given character-offset range.
    public func boxes(overlapping range: Range<Int>) -> [CGRect] {
        spans
            .filter { $0.start < range.upperBound && range.lowerBound < $0.end }
            .map(\.box)
    }
}

/// Map text-locus PHI entities (detected over an `OCRLayout.text`) to image `.region` entities,
/// unioning the boxes of every OCR observation the span touches.
public func imageRegionEntities(from textEntities: [DetectedEntity], layout: OCRLayout) -> [DetectedEntity] {
    textEntities.compactMap { entity in
        guard let offsets = entity.offsets(in: layout.text) else { return nil }
        let boxes = layout.boxes(overlapping: offsets.start..<(offsets.start + offsets.length))
        guard let union = boxes.dropFirst().reduce(boxes.first, { $0?.union($1) }) else { return nil }
        return DetectedEntity(
            type: entity.type,
            value: entity.value,
            confidence: entity.confidence,
            source: entity.source,
            locus: .region(union),
            disposition: entity.disposition
        )
    }
}

/// Which part of an image scan is running. A caller with a progress indicator reports these, so a
/// wait that runs to seconds says what it is waiting on rather than only that it is busy.
public enum ImageScanStage: Sendable {
    /// Vision is reading the picture's text.
    case reading
    /// The detectors are running over that text — the semantic model tier lands here when enabled.
    case findingIdentifiers
    /// The face + barcode passes.
    case checkingFacesAndCodes
}

/// End-to-end image redaction: OCR → detect PHI over the text → map spans back to boxes → add
/// faces → flatten + strip metadata. Deterministic layers run without the LLM.
public struct ImageRedactionPipeline: Sendable {
    private let engine: DetectionEngine
    private let recognizer = VisionTextRecognizer()
    private let faceDetector = VisionFaceDetector()
    private let barcodeDetector = VisionBarcodeDetector()
    private let redactor = ImageRedactor()

    public init(engine: DetectionEngine) {
        self.engine = engine
    }

    public static func makeDefault() throws -> ImageRedactionPipeline {
        let ruleset = try Ruleset.bundled()
        return ImageRedactionPipeline(engine: DetectionEngine(detectors: [
            DataDetectorDetector(),
            try RegexRulesetDetector(ruleset: ruleset),
            DelimitedFieldDetector(),
            NameEntityDetector(),
            CommonNameDetector(),
        ]))
    }

    /// Recognize the image's text as a single string (for copy-text, before any redaction).
    public func recognizeText(in image: CGImage) throws -> String {
        OCRLayout(observations: try recognizer.recognize(image)).text
    }

    /// Detect every redaction region (PHI text boxes + faces) for an image.
    ///
    /// `onStage` fires as each part starts, for a caller showing progress. It reports nothing about
    /// what was found — only which part is running — so it stays safe to surface in a UI.
    public func detectRegions(in image: CGImage,
                              onStage: (@Sendable (ImageScanStage) -> Void)? = nil) async throws -> [DetectedEntity] {
        onStage?(.reading)
        let observations = try recognizer.recognize(image)
        let layout = OCRLayout(observations: observations)
        onStage?(.findingIdentifiers)
        let textEntities = try await engine.detect(in: .text(layout.text))
        var regions = imageRegionEntities(from: textEntities, layout: layout)
        let boxed = SendableImage(image)
        onStage?(.checkingFacesAndCodes)
        // Vision add-ons (faces, barcodes) are non-fatal, mirroring DetectionEngine's per-detector
        // isolation: a failure here must not drop the OCR/text regions. (OCR itself above IS fatal —
        // if we can't read the image at all, fail closed rather than emit partial redaction.)
        for detector in [faceDetector, barcodeDetector] as [any EntityDetector] {
            do {
                regions += try await detector.detect(in: .image(boxed, ocr: observations))
            } catch is CancellationError {
                // A cancelled scan has not finished looking, so it must not read as "found nothing".
                throw CancellationError()
            } catch {
                continue
            }
        }
        return regions
    }

    /// Detect + redact, returning the flattened redacted image (no background yet) and the regions.
    public func redact(_ image: CGImage, style: RedactionStyle = .solid) async throws -> (image: CGImage?, regions: [DetectedEntity]) {
        let regions = try await detectRegions(in: image)
        return (redactor.flattened(image, entities: regions, style: style), regions)
    }
}
