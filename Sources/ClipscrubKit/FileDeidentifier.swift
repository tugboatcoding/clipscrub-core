import Foundation

/// Result of de-identifying a structured medical file: the cleaned bytes + a human-readable summary
/// of what was cleared (no raw values).
public struct DeidentificationResult: Sendable {
    public let data: Data
    public let summary: [String]
}

/// Field-targeted de-identification for structured medical formats whose PHI lives in fixed header
/// fields, not free text (so content-scanning can't find it). Hand-rolled, zero-dependency.
///
/// - **EDF/EDF+** — blanks the local patient- and recording-identification header fields.
/// - **DICOM** — walks the tag stream and blanks the known PHI tags (PS3.15 Basic Profile subset).
///   Values are overwritten **in place** (same length) so the file structure stays valid.
///   Limitations (v1): burned-in **pixel** PHI is not removed (needs a codec for compressed pixel
///   data); UIDs are left intact (re-mapping them consistently is out of scope); nested-sequence
///   PHI past an undefined-length element is not reached.
public enum FileDeidentifier {
    public enum Format: String, Sendable { case dicom, edf }

    public static func format(for url: URL) -> Format? {
        switch url.pathExtension.lowercased() {
        case "dcm", "dicom": return .dicom
        case "edf": return .edf
        default: return nil
        }
    }

    /// Sniff the format from the bytes — clinical DICOM files frequently have no extension.
    public static func detect(_ data: Data) -> Format? {
        if data.count > 132, [UInt8](data[128..<132]) == [0x44, 0x49, 0x43, 0x4D] { return .dicom } // "DICM"
        if data.count >= 256, data[data.startIndex] == 0x30 { return .edf } // EDF version starts "0"
        return nil
    }

    public static func deidentify(_ data: Data, format: Format) -> DeidentificationResult? {
        switch format {
        case .edf: return deidentifyEDF(data)
        case .dicom: return deidentifyDICOM(data)
        }
    }

    // MARK: EDF/EDF+

    static func deidentifyEDF(_ data: Data) -> DeidentificationResult? {
        guard data.count >= 256 else { return nil } // EDF fixed header is 256 bytes
        var bytes = [UInt8](data)
        let space: UInt8 = 0x20
        for i in 8..<88 { bytes[i] = space }   // local patient identification
        for i in 88..<168 { bytes[i] = space } // local recording identification
        return DeidentificationResult(
            data: Data(bytes),
            summary: ["EDF: cleared patient identification (bytes 8–88) and recording identification (88–168); signal data unchanged."]
        )
    }

    // MARK: DICOM (Part-10)

    /// Group<<16 | element for the PHI tags we blank (PS3.15 Basic Profile subset).
    static let dicomPHITags: Set<Int> = [
        0x0008_0050, 0x0008_0080, 0x0008_0081, 0x0008_0090, 0x0008_0092, 0x0008_0094,
        0x0008_1040, 0x0008_1048, 0x0008_1050, 0x0008_1060, 0x0008_1070,
        0x0008_0020, 0x0008_0021, 0x0008_0022, 0x0008_0023, 0x0008_0030, 0x0008_0031, 0x0008_0032, 0x0008_0033,
        0x0010_0010, 0x0010_0020, 0x0010_0021, 0x0010_0030, 0x0010_0032, 0x0010_0040,
        0x0010_1000, 0x0010_1001, 0x0010_1005, 0x0010_1010, 0x0010_1040, 0x0010_2154, 0x0010_4000,
        0x0020_0010,
    ]

    static func deidentifyDICOM(_ data: Data) -> DeidentificationResult? {
        var bytes = [UInt8](data)
        // Part-10: 128-byte preamble + "DICM" magic.
        guard bytes.count > 144,
              bytes[128] == 0x44, bytes[129] == 0x49, bytes[130] == 0x43, bytes[131] == 0x4D else { return nil }

        func u16(_ at: Int) -> Int { Int(bytes[at]) | (Int(bytes[at + 1]) << 8) }
        func u32(_ at: Int) -> Int {
            Int(bytes[at]) | (Int(bytes[at + 1]) << 8) | (Int(bytes[at + 2]) << 16) | (Int(bytes[at + 3]) << 24)
        }
        let longVRs: Set<String> = ["OB", "OW", "OF", "OD", "OL", "SQ", "UT", "UN", "UC", "UR"]
        let undefined = 0xFFFF_FFFF
        let seqDelimiter = (0xFFFE << 16) | 0xE0DD
        let itemDelimiter = (0xFFFE << 16) | 0xE00D

        // Parse one element header at `i`. nil = it would read past the buffer (truncated/malformed →
        // caller fails closed). FFFE items/delimiters are always tag + 4-byte length (no VR).
        func element(at i: Int, explicit: Bool) -> (tag: Int, value: Int, length: Int)? {
            guard i + 8 <= bytes.count else { return nil }
            let tag = (u16(i) << 16) | u16(i + 2)
            if tag >> 16 == 0xFFFE { return (tag, i + 8, u32(i + 4)) }
            if explicit {
                let vr = String(bytes: bytes[(i + 4)..<(i + 6)], encoding: .ascii) ?? ""
                if longVRs.contains(vr) {
                    guard i + 12 <= bytes.count else { return nil }
                    return (tag, i + 12, u32(i + 8))
                }
                return (tag, i + 8, u16(i + 6))
            }
            return (tag, i + 8, u32(i + 4))
        }

        // Skip an undefined-length sequence: items until the Sequence Delimitation Item, recursing
        // through nested undefined-length items. nil = ran off the end (→ fail closed).
        func skipSequence(from start: Int, explicit: Bool) -> Int? {
            var i = start
            while let el = element(at: i, explicit: explicit) {
                if el.tag == seqDelimiter { return el.value }
                if el.length == undefined {
                    guard let end = skipItem(from: el.value, explicit: explicit) else { return nil }
                    i = end
                } else {
                    guard el.value + el.length <= bytes.count, el.value + el.length > i else { return nil }
                    i = el.value + el.length
                }
            }
            return nil
        }
        func skipItem(from start: Int, explicit: Bool) -> Int? {
            var i = start
            while let el = element(at: i, explicit: explicit) {
                if el.tag == itemDelimiter { return el.value }
                if el.length == undefined {
                    guard let end = skipSequence(from: el.value, explicit: explicit) else { return nil }
                    i = end
                } else {
                    guard el.value + el.length <= bytes.count, el.value + el.length > i else { return nil }
                    i = el.value + el.length
                }
            }
            return nil
        }

        // Walk a dataset, blanking PHI tags. Returns the end offset, or **nil if it couldn't scan the
        // whole thing** (truncated header / broken sequence) so the caller never emits a partially
        // scanned file as "de-identified". Sequence-nested tags are skipped, not descended.
        func walk(from start: Int, explicit: Bool, stopAtNonMeta: Bool, onPHI: (Int, Int, Int) -> Void) -> Int? {
            var i = start
            while i + 8 <= bytes.count {
                guard let el = element(at: i, explicit: explicit) else { return nil }
                if stopAtNonMeta, el.tag >> 16 != 0x0002 { return i }
                if el.length == undefined {
                    guard let end = skipSequence(from: el.value, explicit: explicit) else { return nil }
                    i = end
                    continue
                }
                onPHI(el.tag, el.value, el.length)
                let next = el.value + el.length
                guard next <= bytes.count, next > i else { return nil }
                i = next
            }
            return i
        }

        // File Meta group (0002) is always Explicit VR LE. Read TransferSyntaxUID (0002,0010).
        var transferSyntax = ""
        let readMeta: (Int, Int, Int) -> Void = { tag, valueOffset, length in
            if tag == 0x0002_0010, valueOffset + length <= bytes.count {
                transferSyntax = (String(bytes: bytes[valueOffset..<(valueOffset + length)], encoding: .ascii) ?? "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
            }
        }
        guard let afterMeta = walk(from: 132, explicit: true, stopAtNonMeta: true, onPHI: readMeta) else { return nil }

        // Explicit VR Big Endian (retired) uses byte-swapped tags/lengths — we read little-endian, so
        // rather than mis-scan and MISS PHI, refuse it (fail closed).
        if transferSyntax == "1.2.840.10008.1.2.2" { return nil }
        let datasetExplicit = transferSyntax != "1.2.840.10008.1.2"

        var cleared = 0
        guard walk(from: afterMeta, explicit: datasetExplicit, stopAtNonMeta: false, onPHI: { tag, valueOffset, length in
            if dicomPHITags.contains(tag) {
                for k in valueOffset..<min(valueOffset + length, bytes.count) { bytes[k] = 0x20 }
                cleared += 1
            }
        }) != nil else { return nil } // couldn't scan the whole dataset → fail closed

        return DeidentificationResult(
            data: Data(bytes),
            summary: ["DICOM: blanked \(cleared) PHI header tag(s) (name, ID, DOB, sex, dates, physicians, institution…).",
                      "Not modified: burned-in pixel PHI, UIDs, and PHI nested inside sequences. Review before sharing."]
        )
    }
}
