import CoreGraphics
import XCTest
@testable import ClipscrubKit

final class ImagePipelineTests: XCTestCase {
    private let observations = [
        OCRObservation(text: "Patient John Smith", box: CGRect(x: 10, y: 10, width: 200, height: 20)),
        OCRObservation(text: "SSN 123-45-6789", box: CGRect(x: 10, y: 40, width: 200, height: 20)),
    ]

    func testDetectedSpanMapsToOwningOCRBox() async throws {
        let layout = OCRLayout(observations: observations)
        let entities = try await RedactionPipeline.makeDefault().detect(text: layout.text)
        let mapped = imageRegionEntities(from: entities, layout: layout)

        let ssn = try XCTUnwrap(mapped.first { $0.type == .ssn })
        guard case let .region(box) = ssn.locus else { return XCTFail("expected a region locus") }
        XCTAssertEqual(box.minX, 10, accuracy: 0.5)
        XCTAssertEqual(box.minY, 40, accuracy: 0.5) // the second OCR line, not the first
        XCTAssertTrue(mapped.allSatisfy { if case .region = $0.locus { return true }; return false })
    }

    func testSpanCrossingTwoObservationsUnionsBoxes() {
        // "John" is in box A, "Smith" in box B; a span covering both unions the two.
        let obs = [
            OCRObservation(text: "John", box: CGRect(x: 0, y: 0, width: 40, height: 10)),
            OCRObservation(text: "Smith", box: CGRect(x: 100, y: 0, width: 50, height: 10)),
        ]
        let layout = OCRLayout(observations: obs, separator: " ")
        // Whole joined string "John Smith" as one detected NAME span.
        let whole = layout.text.startIndex..<layout.text.endIndex
        let entity = DetectedEntity(type: .name, value: layout.text, confidence: 0.6,
                                    source: .nlTagger, locus: .text(whole))
        let mapped = imageRegionEntities(from: [entity], layout: layout)
        guard case let .region(box) = try! XCTUnwrap(mapped.first).locus else { return XCTFail() }
        XCTAssertEqual(box.minX, 0, accuracy: 0.5)
        XCTAssertEqual(box.maxX, 150, accuracy: 0.5) // union spans both boxes
    }
}
