import Foundation

/// Reads a CSV or TSV export and identifies values by the COLUMN THEY SIT IN.
///
/// Some identifiers have no shape to match. Every insurer invents its own member-ID format, so a
/// pattern that catches `MHP-4471-88203-01` misses the next payer's, and one loose enough to catch
/// both marks every order number in the file. A regex is the wrong instrument.
///
/// A claims export answers the question in its first line. `member_id` names the column, and every
/// value beneath it is a member ID whatever it looks like. That is the whole idea here: read the
/// header, then trust it. It is also what a general-purpose detector cannot do, because it only
/// ever sees the value.
///
/// Deliberately narrow. It fires only on something that really is a table — several columns, rows
/// that all agree on how many, and at least one header it recognises. Prose with commas in it does
/// not survive those checks, and a file this is unsure about is left to the other layers.
public struct DelimitedFieldDetector: EntityDetector {
    public let source: DetectionSource = .structuredField

    /// A cell in a `flag` column has to look like the code the header promises.
    ///
    /// Without this the header alone decides, and a `diagnosis` column holding free text — which is
    /// most of them — hands a whole sentence to `flag`, so `Generalised anxiety; spouse Priya
    /// Raghavan present` is found, kept, and the name inside it never reaches the detector that
    /// would have removed it. Flagging is the one disposition that leaves PHI in the document, so
    /// it has to be sure. A cell that fails is left to the other layers, which redact.
    static let codeShapes: [String: NSRegularExpression] = {
        let patterns = [
            "cpt": "^[0-9]{5}$|^[A-Za-z][0-9]{4}$",
            "icd10": "^[A-TVa-tv-z][0-9][0-9ABab](\\.[0-9A-TVa-tv-z]{1,4})?$",
        ]
        return patterns.compactMapValues { try? NSRegularExpression(pattern: $0) }
    }()

    /// Header name (letters and digits only, lowercased) → what the column holds.
    ///
    /// Add a column name here and every value under it is found, in every file that uses it. Names
    /// are matched WHOLE: `id` alone is not on this list because a bare `id` column is as likely to
    /// be a row number as anything about a person, and a bare `name` as likely to be a product.
    ///
    /// SHARED WITH `JSONFieldDetector`, which reads the same names off JSON object keys — so a name
    /// added here starts being found in `.json` too, not only in `.csv`. That is the intent: it is
    /// one list of "field names that hold a person", and the two detectors differ only in the file
    /// shape they read it from.
    static let columns: [String: (type: EntityType, disposition: Disposition)] = [
        "memberid": (.beneficiary, .redact),
        "membernumber": (.beneficiary, .redact),
        "memberno": (.beneficiary, .redact),
        "subscriberid": (.beneficiary, .redact),
        "policyid": (.beneficiary, .redact),
        "policynumber": (.beneficiary, .redact),
        "beneficiaryid": (.beneficiary, .redact),
        "insuredid": (.beneficiary, .redact),
        "enrolleeid": (.beneficiary, .redact),
        "mrn": (.mrn, .redact),
        "medicalrecordnumber": (.mrn, .redact),
        "medicalrecordno": (.mrn, .redact),
        "patientid": (.mrn, .redact),
        "chartnumber": (.mrn, .redact),
        "ssn": (.ssn, .redact),
        "socialsecuritynumber": (.ssn, .redact),
        "dob": (.dateOfBirth, .redact),
        "dateofbirth": (.dateOfBirth, .redact),
        "birthdate": (.dateOfBirth, .redact),
        "membername": (.name, .redact),
        "patientname": (.name, .redact),
        "subscribername": (.name, .redact),
        "beneficiaryname": (.name, .redact),
        "insuredname": (.name, .redact),
        // Safe Harbor B covers subdivisions SMALLER than a state, so `state` is deliberately not
        // here — redacting it removes something the rule lets the reader keep.
        "address": (.address, .redact),
        "address1": (.address, .redact),
        "addressline1": (.address, .redact),
        "streetaddress": (.address, .redact),
        "street": (.address, .redact),
        "city": (.address, .redact),
        "town": (.address, .redact),
        "zip": (.address, .redact),
        "zipcode": (.address, .redact),
        "postalcode": (.address, .redact),
        "postcode": (.address, .redact),
        // Found for the same reason as everything else here, and kept for the reason in
        // `Disposition`: the code is usually why the export is being shared.
        "cpt": (.other("cpt"), .flag),
        "cptcode": (.other("cpt"), .flag),
        "hcpcs": (.other("cpt"), .flag),
        "procedurecode": (.other("cpt"), .flag),
        "dx": (.other("icd10"), .flag),
        "diagnosis": (.other("icd10"), .flag),
        "diagnosiscode": (.other("icd10"), .flag),
        "icd": (.other("icd10"), .flag),
        "icd10": (.other("icd10"), .flag),
    ]

    /// A table needs at least this many columns before the header is believed. Two columns is as
    /// easily a sentence with a comma in it.
    private static let minimumColumns = 3

    public init() {}

    public func detect(in input: DetectionInput) async throws -> [DetectedEntity] {
        guard case let .text(text) = input, !text.isEmpty else { return [] }
        let lines = Self.lines(of: text)
        guard let header = lines.first, lines.count >= 2 else { return [] }

        for delimiter in [",", "\t"] as [Character] {
            let headerFields = Self.fields(in: header, of: text, delimiter: delimiter)
            guard headerFields.count >= Self.minimumColumns else { continue }

            let wanted = headerFields.enumerated().reduce(into: [Int: (type: EntityType, disposition: Disposition)]()) {
                if let column = Self.columns[Self.normalise(String(text[$1.element]))] { $0[$1.offset] = column }
            }
            guard !wanted.isEmpty else { continue }

            let rows = lines.dropFirst().filter { !text[$0].trimmingCharacters(in: .whitespaces).isEmpty }
            let rowFields = rows.map { Self.fields(in: $0, of: text, delimiter: delimiter) }
            // Every row agreeing with the header is what separates a table from prose that happens
            // to contain commas. One row that doesn't means the split is wrong, and a wrong split
            // reads the neighbouring column's value — so nothing is reported at all.
            guard !rowFields.isEmpty, rowFields.allSatisfy({ $0.count == headerFields.count }) else { continue }

            return rowFields.flatMap { fields in
                wanted.compactMap { index, column -> DetectedEntity? in
                    // nil covers empty: `trimmed` returns a range only when something is left.
                    guard let range = Self.trimmed(fields[index], in: text) else { return nil }
                    guard Self.shapeAllows(column, value: text[range]) else { return nil }
                    return DetectedEntity(
                        type: column.type,
                        value: String(text[range]),
                        confidence: 0.9,
                        source: .structuredField,
                        locus: .text(range),
                        disposition: column.disposition
                    )
                }
            }
        }
        return []
    }

    /// Whether this cell may be claimed by its column.
    ///
    /// Only `flag` columns are checked. A `redact` column that guesses wrong removes something it
    /// did not have to, which costs the reader a word. A `flag` column that guesses wrong leaves
    /// PHI in the document.
    static func shapeAllows(_ column: (type: EntityType, disposition: Disposition), value: Substring) -> Bool {
        guard column.disposition == .flag else { return true }
        guard case let .other(subtype) = column.type, let shape = codeShapes[subtype] else { return false }
        let text = String(value)
        return shape.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func normalise(_ header: String) -> String {
        header.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func lines(of text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\n" {
                result.append(start..<index)
                start = text.index(after: index)
            }
            index = text.index(after: index)
        }
        if start < text.endIndex { result.append(start..<text.endIndex) }
        return result
    }

    /// Split one line on `delimiter`, honouring double quotes.
    ///
    /// Quoting matters for placement, not just tidiness: a quoted `"Covington, KY"` split naively
    /// becomes two fields and shifts every column after it by one, so the detector would read the
    /// wrong column and mark the wrong value.
    private static func fields(in line: Range<String.Index>, of text: String, delimiter: Character) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start = line.lowerBound
        var index = line.lowerBound
        var inQuotes = false
        while index < line.upperBound {
            let character = text[index]
            if character == "\"" {
                inQuotes.toggle()
            } else if character == delimiter, !inQuotes {
                result.append(start..<index)
                start = text.index(after: index)
            }
            index = text.index(after: index)
        }
        result.append(start..<line.upperBound)
        return result
    }

    /// The field without its surrounding spaces and quotes, so the redaction box covers the value
    /// and not the punctuation holding it.
    private static func trimmed(_ field: Range<String.Index>, in text: String) -> Range<String.Index>? {
        var start = field.lowerBound
        var end = field.upperBound
        let strippable: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\"" || $0 == "\r" }
        while start < end, strippable(text[start]) { start = text.index(after: start) }
        while start < end, strippable(text[text.index(before: end)]) { end = text.index(before: end) }
        return start < end ? start..<end : nil
    }
}
