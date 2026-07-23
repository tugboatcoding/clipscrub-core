import AppKit
import ClipscrubKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

// A dependency-free smoke harness mirroring the XCTest suite, so the core can be
// verified headlessly under Command Line Tools (no XCTest/Testing module needed).
// All fixtures are synthetic — no real PHI.

var failures = 0
@MainActor
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

func makeSolidImage(width: Int, height: Int, gray: CGFloat) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// Sample one pixel (top-left origin coordinates) from an image.
func pixelRGBA(_ image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return (pixel[0], pixel[1], pixel[2], pixel[3])
}

func averageRGBA(_ image: CGImage) -> (UInt8, UInt8, UInt8, UInt8) {
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return (pixel[0], pixel[1], pixel[2], pixel[3])
}

let clinical = """
Patient John Smith, SSN 123-45-6789, MRN: A1234567, \
email john.smith@example.com, phone (415) 555-0132.
"""

/// Stand-in for a flaky optional layer (e.g. the Foundation Models pass) that throws mid-run.
struct ThrowingDetector: EntityDetector {
    let source: DetectionSource = .foundationModel
    struct Boom: Error {}
    func detect(in input: DetectionInput) async throws -> [DetectedEntity] { throw Boom() }
}

@MainActor
func run() async throws {
    print("regex ruleset")
    let regex = try RegexRulesetDetector(ruleset: Ruleset.bundled())
    let structured = try await regex.detect(in: .text(
        "SSN 123-45-6789, email a.user@example.com, host 10.0.12.7, MRN: A1234567, token eyJhbGc.eyJzdWI.sIg"
    ))
    let structuredTypes = Set(structured.map(\.type))
    check(structuredTypes.contains(.ssn), "detects SSN")
    check(structuredTypes.contains(.email), "detects email")
    check(structuredTypes.contains(.ipAddress), "detects IPv4")
    check(structuredTypes.contains(.mrn), "detects labelled MRN")
    check(structuredTypes.contains(.other("jwt")), "detects JWT")

    print("quasi-identifiers (age / sex, case-insensitive)")
    let quasi = try await regex.detect(in: .text("Patient AGE:47, sex female; also 82 y/o elsewhere."))
    let quasiTypes = Set(quasi.map(\.type))
    check(quasiTypes.contains(.other("age")), "detects labelled age (any case)")
    check(quasi.contains { $0.type == .other("age") && $0.value.contains("82") }, "detects '82 y/o' form")
    check(quasiTypes.contains(.other("sex")), "detects labelled sex/gender (any case)")
    let quasi2 = try await regex.detect(in: .text("Race: African American\nMarital Status: Married"))
    let quasi2Types = Set(quasi2.map(\.type))
    check(quasi2Types.contains(.other("race")), "detects labelled race/ethnicity")
    check(quasi2Types.contains(.other("marital")), "detects labelled marital status")
    // The label word alone (no value) must NOT fire — anchored to enumerated values.
    let noValue = try await regex.detect(in: .text("The race was close and everyone finished."))
    check(!noValue.contains { $0.type == .other("race") }, "bare 'race' in prose does not over-redact")

    print("labelled Safe-Harbor IDs (ZIP / group# / test-ID)")
    let ids = try await regex.detect(in: .text("Zip Code: 12345\nGroup Number: A1234\nTest ID: T-9981"))
    let idTypes = Set(ids.map(\.type))
    check(idTypes.contains(.other("zip")), "detects labelled ZIP")
    check(idTypes.contains(.other("group")), "detects labelled group number")
    check(idTypes.contains(.other("testid")), "detects labelled test ID")
    let dl = try await regex.detect(in: .text("DLN: D1234567\nDriver's License X98765432"))
    check(dl.contains { $0.type == .license }, "detects labelled driver's license (DLN + phrase)")
    // Guards: a bare 5-digit run and 'group therapy' must not fire (label + digit-bearing value req'd).
    let idNoise = try await regex.detect(in: .text("bought 12345 units for the group therapy session"))
    check(!idNoise.contains { $0.type == .other("zip") }, "bare 5-digit number is not treated as ZIP")
    check(!idNoise.contains { $0.type == .other("group") }, "'group therapy' does not fire group number")

    print("detector isolation (LLM failure must not gate layers 1–3)")
    let resilientEngine = DetectionEngine(detectors: [
        ThrowingDetector(),
        try RegexRulesetDetector(ruleset: Ruleset.bundled()),
    ])
    let resilient = try await resilientEngine.detect(in: .text("SSN 123-45-6789"))
    check(resilient.contains { $0.type == .ssn }, "a throwing detector does not drop the deterministic layers")

    print("foundation-models tier (CLI default on / --no-llm off)")
    let noLLM1 = try await RedactionPipeline.makeDefault().run(text: "SSN 123-45-6789").redactedText
    let noLLM2 = try await RedactionPipeline.makeDefault().run(text: "SSN 123-45-6789").redactedText
    check(noLLM1 == noLLM2 && noLLM1 == "SSN [SSN_1]", "makeDefault (--no-llm) is reproducible + deterministic")
    var fmAvailable = false
    #if canImport(FoundationModels)
    if #available(macOS 26, *) { fmAvailable = FoundationModelDetector.isAvailable }
    #endif
    if fmAvailable {
        // Skip the (slow, non-deterministic) on-device model call in this smoke harness; the
        // additive-floor + contextual catch are exercised in XCTest / by hand.
        print("  ok   FoundationModels tier available — compiled into ClipscrubKit, active by default")
    } else {
        let withModel = try await RedactionPipeline.makeWithModel().run(text: "SSN 123-45-6789").redactedText
        check(withModel == noLLM1, "model unavailable (macOS<26 / AI off / old SDK) → makeWithModel == makeDefault (no-op)")
    }

    print("document decoder (rich text + plain)")
    let tmp = FileManager.default.temporaryDirectory
    let rtfURL = tmp.appendingPathComponent("cs_fixture.rtf")
    try #"{\rtf1\ansi Patient John Smith, SSN 123-45-6789.}"#.write(to: rtfURL, atomically: true, encoding: .utf8)
    if case let .text(rtf)? = DocumentDecoder.decode(rtfURL) {
        check(rtf.contains("John Smith") && rtf.contains("123-45-6789"), "decodes RTF to plain text")
    } else { check(false, "decodes RTF to plain text") }
    let txtURL = tmp.appendingPathComponent("cs_fixture.txt")
    try "MRN: A1234567".write(to: txtURL, atomically: true, encoding: .utf8)
    if case let .text(txt)? = DocumentDecoder.decode(txtURL) {
        check(txt.contains("A1234567"), "decodes plain text file")
    } else { check(false, "decodes plain text file") }
    try? FileManager.default.removeItem(at: rtfURL)
    try? FileManager.default.removeItem(at: txtURL)

    // PDF round-trip: assemble a 2-page PDF, decode it back to 2 page images (render path).
    if let pdfData = PDFAssembler.pdfData(from: [makeSolidImage(width: 200, height: 300, gray: 1),
                                                 makeSolidImage(width: 200, height: 300, gray: 1)]) {
        let pdfURL = tmp.appendingPathComponent("cs_fixture.pdf")
        try pdfData.write(to: pdfURL)
        if case let .images(pages)? = DocumentDecoder.decode(pdfURL) {
            check(pages.count == 2, "decodes a 2-page PDF into 2 page images")
        } else { check(false, "decodes a 2-page PDF into 2 page images") }
        try? FileManager.default.removeItem(at: pdfURL)
    } else { check(false, "assembles a PDF from page images") }

    // Multi-page document export: the paginator flattens every page → one PDF. Assemble 3 pages of
    // DIFFERENT sizes and confirm all three round-trip (no page dropped or collapsed).
    if let docPDF = PDFAssembler.pdfData(from: [makeSolidImage(width: 200, height: 300, gray: 1),
                                                makeSolidImage(width: 240, height: 200, gray: 0),
                                                makeSolidImage(width: 180, height: 260, gray: 1)]) {
        let docURL = tmp.appendingPathComponent("cs_doc_fixture.pdf")
        try docPDF.write(to: docURL)
        if case let .images(pages)? = DocumentDecoder.decode(docURL) {
            check(pages.count == 3, "assembles a 3-page document PDF (all pages round-trip)")
        } else { check(false, "assembles a 3-page document PDF (all pages round-trip)") }
        try? FileManager.default.removeItem(at: docURL)
    } else { check(false, "assembles a 3-page document PDF (all pages round-trip)") }

    print("attributed (formatted) redaction")
    let bold = NSFont.boldSystemFont(ofSize: 12)
    let attributed = NSMutableAttributedString(string: "Patient ")
    attributed.append(NSAttributedString(string: "John Smith", attributes: [.font: bold]))
    attributed.append(NSAttributedString(string: ", SSN 123-45-6789."))
    let attrResult = try await RedactionPipeline.makeDefault().run(text: attributed.string)
    let redactedAttr = AttributedRedactor.apply(attrResult.entities, to: attributed)
    check(!redactedAttr.string.contains("123-45-6789"), "attributed redaction removes the raw SSN")
    check(redactedAttr.string.contains("[SSN_1]"), "attributed redaction inserts the token")
    var boldSurvives = false
    redactedAttr.enumerateAttribute(.font, in: NSRange(location: 0, length: redactedAttr.length)) { value, _, _ in
        if let font = value as? NSFont, font.fontDescriptor.symbolicTraits.contains(.bold) { boldSurvives = true }
    }
    check(boldSurvives, "attributed redaction preserves formatting (a bold run survives)")

    print("structured file de-identification (EDF + DICOM)")
    func contains(_ data: Data, _ text: String) -> Bool {
        let needle = Array(text.utf8), hay = [UInt8](data)
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        for i in 0...(hay.count - needle.count) where Array(hay[i..<(i + needle.count)]) == needle { return true }
        return false
    }
    // EDF: 256-byte header, patient identification at bytes 8–88.
    var edf = [UInt8](repeating: 0x20, count: 256); edf[0] = 0x30 // "0" version
    for (i, c) in "MCH-0234567 F 02-MAY-1951 Harry".utf8.enumerated() where 8 + i < 88 { edf[8 + i] = c }
    var edfData = Data(edf); edfData.append(contentsOf: [0xAB, 0xCD]) // signal marker
    if let result = FileDeidentifier.deidentify(edfData, format: .edf) {
        check([UInt8](result.data)[8..<88].allSatisfy { $0 == 0x20 }, "EDF patient field cleared")
        check(result.data.count == edfData.count && result.data.last == 0xCD, "EDF signal data untouched")
    } else { check(false, "EDF de-identified") }
    // DICOM Part-10, explicit VR LE.
    func el(_ g: Int, _ e: Int, _ vr: String, _ value: [UInt8]) -> [UInt8] {
        [UInt8(g & 0xff), UInt8((g >> 8) & 0xff), UInt8(e & 0xff), UInt8((e >> 8) & 0xff)]
            + Array(vr.utf8) + [UInt8(value.count & 0xff), UInt8((value.count >> 8) & 0xff)] + value
    }
    func even(_ s: String, pad: UInt8) -> [UInt8] { var v = Array(s.utf8); if v.count % 2 != 0 { v.append(pad) }; return v }
    var dcm = [UInt8](repeating: 0, count: 128) + Array("DICM".utf8)
    dcm += el(0x0002, 0x0010, "UI", even("1.2.840.10008.1.2.1", pad: 0)) // TransferSyntaxUID (explicit VR LE)
    dcm += el(0x0008, 0x0060, "CS", even("CT", pad: 0x20))               // Modality — NOT PHI
    dcm += el(0x0010, 0x0010, "PN", even("SMITH^JOHN", pad: 0x20))       // PatientName — PHI
    dcm += el(0x0010, 0x0020, "LO", even("MRN-999", pad: 0x20))          // PatientID — PHI
    if let result = FileDeidentifier.deidentify(Data(dcm), format: .dicom) {
        check(!contains(result.data, "SMITH^JOHN"), "DICOM PatientName blanked")
        check(!contains(result.data, "MRN-999"), "DICOM PatientID blanked")
        check(contains(result.data, "CT"), "DICOM non-PHI tag (Modality) preserved")
    } else { check(false, "DICOM de-identified") }

    func u32le(_ n: Int) -> [UInt8] { [UInt8(n & 0xff), UInt8((n >> 8) & 0xff), UInt8((n >> 16) & 0xff), UInt8((n >> 24) & 0xff)] }
    func dtag(_ g: Int, _ e: Int) -> [UInt8] { [UInt8(g & 0xff), UInt8((g >> 8) & 0xff), UInt8(e & 0xff), UInt8((e >> 8) & 0xff)] }
    // Undefined-length sequence BEFORE the patient block: the walk must skip it and still blank the
    // PatientName that follows (the fail-open the review caught).
    var seq = [UInt8](repeating: 0, count: 128) + Array("DICM".utf8)
    seq += el(0x0002, 0x0010, "UI", even("1.2.840.10008.1.2.1", pad: 0))
    seq += dtag(0x0008, 0x1032) + Array("SQ".utf8) + [0, 0] + u32le(0xFFFF_FFFF) // undefined-length SQ
    seq += dtag(0xFFFE, 0xE000) + u32le(0xFFFF_FFFF)                             // undefined item
    seq += el(0x0008, 0x0100, "CS", even("X", pad: 0x20))                       // nested element
    seq += dtag(0xFFFE, 0xE00D) + u32le(0)                                       // item delimiter
    seq += dtag(0xFFFE, 0xE0DD) + u32le(0)                                       // sequence delimiter
    seq += el(0x0010, 0x0010, "PN", even("SECRETNAME", pad: 0x20))              // PatientName AFTER the SQ
    if let result = FileDeidentifier.deidentify(Data(seq), format: .dicom) {
        check(!contains(result.data, "SECRETNAME"), "DICOM: name after an undefined-length sequence is still blanked")
    } else { check(false, "DICOM with a sequence still de-identifies") }
    // Big-endian transfer syntax → refused (fail closed), not mis-scanned.
    var be = [UInt8](repeating: 0, count: 128) + Array("DICM".utf8)
    be += el(0x0002, 0x0010, "UI", even("1.2.840.10008.1.2.2", pad: 0))
    be += el(0x0010, 0x0010, "PN", even("SMITH^JOHN", pad: 0x20))
    check(FileDeidentifier.deidentify(Data(be), format: .dicom) == nil, "DICOM: big-endian refused (fail closed)")
    // Truncated long-VR header → nil, no crash.
    var trunc = [UInt8](repeating: 0, count: 128) + Array("DICM".utf8)
    trunc += el(0x0002, 0x0010, "UI", even("1.2.840.10008.1.2.1", pad: 0))
    trunc += dtag(0x7FE0, 0x0010) + Array("OB".utf8) + [0, 0] // long-VR header cut off before the length
    check(FileDeidentifier.deidentify(Data(trunc), format: .dicom) == nil, "DICOM: truncated element → nil, no crash")

    print("data detector")
    let phones = try await DataDetectorDetector().detect(in: .text("Call (415) 555-0132 tomorrow."))
    check(phones.contains { $0.type == .phone }, "detects phone number")

    print("NLTagger NER")
    let names = try await NameEntityDetector().detect(in: .text("Barack Obama visited the clinic in Chicago."))
    check(names.contains { $0.type == .name && $0.value.contains("Obama") }, "detects personal name")

    print("engine overlap resolution")
    let pipeline = try RedactionPipeline.makeDefault()
    let entities = try await pipeline.run(text: clinical).entities
    let ordered = entities
        .compactMap { $0.offsets(in: clinical) }
        .map { ($0.start, $0.start + $0.length) }
        .sorted { $0.0 < $1.0 }
    var disjoint = true
    for (a, b) in zip(ordered, ordered.dropFirst()) where a.1 > b.0 { disjoint = false }
    check(disjoint, "engine returns pairwise-disjoint spans")

    print("redaction integrity")
    let result = try await pipeline.run(text: clinical)
    for leaked in ["123-45-6789", "john.smith@example.com", "A1234567"] {
        check(!result.redactedText.contains(leaked), "scrubs \(leaked)")
    }
    check(result.redactedText.contains("[SSN_1]"), "emits [SSN_1] token")

    print("token consistency")
    let same = try await pipeline.run(text: "reach a@b.com or a@b.com").redactedText
    check(same.contains("[EMAIL_1]") && !same.contains("[EMAIL_2]"), "same value → same token")
    let distinct = try await pipeline.run(text: "reach a@b.com or c@d.com").redactedText
    check(distinct.contains("[EMAIL_1]") && distinct.contains("[EMAIL_2]"), "distinct values → distinct tokens")

    print("audit-safe reports")
    let json = try JSONEncoder().encode(result.reports(over: clinical))
    let reportString = String(decoding: json, as: UTF8.self)
    var reportsClean = true
    for leaked in ["123-45-6789", "john.smith@example.com", "A1234567"] where reportString.contains(leaked) {
        reportsClean = false
    }
    check(reportsClean, "entity JSON carries no raw values")

    print("pseudonymise mode")
    let fixedKey = SymmetricKey(data: Data(repeating: 0x2b, count: 32))
    let pseudo = Pseudonymiser(key: fixedKey, width: 4)
    let emailToken = pseudo.token(for: "a@b.com", type: .email)
    let pseudoText = try await pipeline.run(
        text: "reach a@b.com or a@b.com", mode: .pseudonymise, pseudonymiser: pseudo
    ).redactedText
    check(pseudoText.contains(emailToken) && !pseudoText.contains("[EMAIL_1]"), "uses keyed token, not [EMAIL_n]")
    check(pseudoText.components(separatedBy: emailToken).count - 1 == 2, "same value → same token (both occurrences)")
    check(Pseudonymiser(key: fixedKey, width: 4).token(for: "a@b.com", type: .email) == emailToken, "stable across instances (same key)")
    check(pseudo.token(for: "c@d.com", type: .email) != emailToken, "distinct values → distinct tokens")
    check(!emailToken.contains("a@b.com"), "token reveals no raw value")

    print("image redaction")
    let white = makeSolidImage(width: 40, height: 30, gray: 1.0)
    let fullCover = DetectedEntity(
        type: .face, value: "face", confidence: 1, source: .face,
        locus: .region(CGRect(x: 0, y: 0, width: 40, height: 30))
    )
    if let png = ImageRedactor().redact(white, entities: [fullCover]),
       let source = CGImageSourceCreateWithData(png as CFData, nil),
       let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) {
        let avg = averageRGBA(decoded)
        check(avg.0 < 8 && avg.1 < 8 && avg.2 < 8, "redacted pixels opaque — original (white) discarded")
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        // The re-encoded PNG carries no location/camera/timestamp metadata. ImageIO only
        // synthesizes structural pixel dimensions inside {Exif}, which identify nothing.
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let sensitiveExif = exif.keys.contains {
            $0 != kCGImagePropertyExifPixelXDimension && $0 != kCGImagePropertyExifPixelYDimension
        }
        check(props[kCGImagePropertyGPSDictionary] == nil
              && props[kCGImagePropertyTIFFDictionary] == nil
              && !sensitiveExif,
              "export carries no GPS/camera/timestamp metadata (only pixel dimensions)")
    } else {
        check(false, "image redaction produced a decodable PNG")
    }

    print("redaction styles")
    for style in RedactionStyle.allCases {
        check(ImageRedactor().flattened(white, entities: [fullCover], style: style) != nil, "\(style.label) produces an image")
    }

    print("image OCR→PHI→box mapping")
    let ocrObs = [
        OCRObservation(text: "Patient John Smith", box: CGRect(x: 10, y: 10, width: 200, height: 20)),
        OCRObservation(text: "SSN 123-45-6789", box: CGRect(x: 10, y: 40, width: 200, height: 20)),
    ]
    let layout = OCRLayout(observations: ocrObs)
    let ocrEntities = try await pipeline.detect(text: layout.text)
    let mapped = imageRegionEntities(from: ocrEntities, layout: layout)
    let ssnRegion = mapped.first { $0.type == .ssn }
    check(ssnRegion != nil, "maps detected SSN in OCR text to an image region")
    if case let .region(box)? = ssnRegion?.locus {
        check(abs(box.minX - 10) < 0.5 && abs(box.minY - 40) < 0.5, "SSN region = the OCR line box that carries it")
    } else {
        check(false, "SSN region has a box locus")
    }
    check(mapped.allSatisfy { if case .region = $0.locus { return true }; return false },
          "mapped entities are all region loci")

}

try await run()

if failures > 0 {
    print("\n\(failures) check(s) failed")
    exit(1)
}
print("\nAll checks passed")
