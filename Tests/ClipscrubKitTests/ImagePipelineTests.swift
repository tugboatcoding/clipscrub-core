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

    /// A line reads "MRN 88-40021 F41.1". Removing the MRN must not take the diagnosis code with
    /// it — the code is usually why the page is being shared at all. Before per-word boxes existed
    /// the only box available was the whole line, so the whole line went black and `F41.1` with it.
    func testRemovingOneWordLeavesTheRestOfItsLineAlone() {
        // Boxes as Vision reports them: one line box, plus where each word sits inside it.
        let line = OCRObservation(
            text: "MRN 88-40021 F41.1",
            box: CGRect(x: 10, y: 40, width: 300, height: 20),
            wordBoxes: [
                .init(range: 0..<3, box: CGRect(x: 10, y: 40, width: 50, height: 20)),
                .init(range: 4..<12, box: CGRect(x: 65, y: 40, width: 130, height: 20)),
                .init(range: 13..<18, box: CGRect(x: 200, y: 40, width: 110, height: 20)),
            ]
        )
        let layout = OCRLayout(observations: [line])
        let mrn = try! XCTUnwrap(layout.text.range(of: "MRN 88-40021"))
        let entity = DetectedEntity(type: .mrn, value: "MRN 88-40021", confidence: 0.9,
                                    source: .regex, locus: .text(mrn))

        guard case let .region(box) = try! XCTUnwrap(imageRegionEntities(from: [entity], layout: layout).first).locus
        else { return XCTFail("expected a region locus") }

        XCTAssertEqual(box.minX, 10, accuracy: 0.5)
        XCTAssertEqual(box.maxX, 195, accuracy: 0.5, "the box must stop before F41.1 starts at x=200")
        XCTAssertLessThan(box.maxX, 200, "F41.1 was covered — this is the whole-line regression")
    }

    /// No word geometry is the case to get wrong in the safe direction. Covering too much only
    /// costs the reader some context. Covering too little leaves the identifier on the page.
    func testMissingWordBoxesFallsBackToCoveringTheWholeLine() {
        let line = OCRObservation(text: "MRN 88-40021 F41.1",
                                  box: CGRect(x: 10, y: 40, width: 300, height: 20))
        let layout = OCRLayout(observations: [line])
        let mrn = try! XCTUnwrap(layout.text.range(of: "MRN 88-40021"))
        let entity = DetectedEntity(type: .mrn, value: "MRN 88-40021", confidence: 0.9,
                                    source: .regex, locus: .text(mrn))

        guard case let .region(box) = try! XCTUnwrap(imageRegionEntities(from: [entity], layout: layout).first).locus
        else { return XCTFail("expected a region locus") }
        XCTAssertEqual(box, line.box)
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
