import CoreGraphics
import Foundation

/// Which pipeline layer produced a detection. Kept on every entity so callers can
/// show provenance in reports and log the detector (never the value).
public enum DetectionSource: String, Codable, Sendable, CaseIterable {
    case dataDetector
    case regex
    case nlTagger
    case vision
    case face
    case foundationModel
    case coreML
    case manual
    /// Identified by the column or key it sits under, not by what it looks like.
    case structuredField
}

/// HIPAA Safe Harbor-aligned identifier categories (+ faces). `other` carries a
/// free-form subtype for the "any other unique identifying number/code" bucket
/// (also used for NER organisation/place tags).
public enum EntityType: Codable, Sendable, Hashable {
    case name
    case address
    case dateOfBirth
    case date
    case phone
    case fax
    case email
    case ssn
    case mrn
    case beneficiary
    case account
    case license
    case vehicle
    case device
    case url
    case ipAddress
    case biometric
    case face
    case other(String)
}

public extension EntityType {
    /// Uppercase token stem used in redaction output, e.g. `[NAME_1]`.
    var tokenPrefix: String {
        switch self {
        case .name: "NAME"
        case .address: "ADDRESS"
        case .dateOfBirth: "DOB"
        case .date: "DATE"
        case .phone: "PHONE"
        case .fax: "FAX"
        case .email: "EMAIL"
        case .ssn: "SSN"
        case .mrn: "MRN"
        case .beneficiary: "BENEFICIARY"
        case .account: "ACCOUNT"
        case .license: "LICENSE"
        case .vehicle: "VEHICLE"
        case .device: "DEVICE"
        case .url: "URL"
        case .ipAddress: "IP"
        case .biometric: "BIOMETRIC"
        case .face: "FACE"
        case .other(let subtype): subtype.uppercased()
        }
    }

    /// Stable lowercase identifier for ruleset config + entity JSON output.
    var identifier: String {
        switch self {
        case .name: "name"
        case .address: "address"
        case .dateOfBirth: "dob"
        case .date: "date"
        case .phone: "phone"
        case .fax: "fax"
        case .email: "email"
        case .ssn: "ssn"
        case .mrn: "mrn"
        case .beneficiary: "beneficiary"
        case .account: "account"
        case .license: "license"
        case .vehicle: "vehicle"
        case .device: "device"
        case .url: "url"
        case .ipAddress: "ip"
        case .biometric: "biometric"
        case .face: "face"
        case .other(let subtype): subtype.lowercased()
        }
    }

    /// Map a ruleset/config string to a category; unknown strings fall into `.other`.
    init(identifier: String) {
        switch identifier.lowercased() {
        case "name": self = .name
        case "address": self = .address
        case "dob", "dateofbirth": self = .dateOfBirth
        case "date": self = .date
        case "phone": self = .phone
        case "fax": self = .fax
        case "email": self = .email
        case "ssn": self = .ssn
        case "mrn": self = .mrn
        case "beneficiary": self = .beneficiary
        case "account": self = .account
        case "license": self = .license
        case "vehicle": self = .vehicle
        case "device": self = .device
        case "url": self = .url
        case "ip", "ipaddress": self = .ipAddress
        case "biometric": self = .biometric
        case "face": self = .face
        default: self = .other(identifier)
        }
    }
}

/// Where a detection sits in its input. Text uses a character range over the exact
/// source string; images use a rect in **pixel** space (post-orientation).
public enum Locus: Sendable {
    case text(Range<String.Index>)
    case region(CGRect)
}

/// What finding a thing should DO to it.
///
/// Not everything worth pointing at is worth deleting. A CPT procedure code is usually the reason
/// a document is being shared at all — remove `90837` from an insurance denial and the question
/// "why was this denied?" goes with it. Same for a diagnosis code. These are not Safe Harbor
/// identifiers, and taking them out silently destroys the document while looking like caution.
///
/// So a rule can ask for `flag` instead: still detected, still listed, but left in the output and
/// switched off in review, one click from being removed if that is what the reader wants.
public enum Disposition: String, Codable, Sendable, CaseIterable {
    /// Remove it. The default, and what every Safe Harbor identifier gets.
    case redact
    /// Point at it and leave it alone.
    case flag
}

/// A single detected identifier. `value` is held in memory only for redaction/review
/// and must NEVER be persisted in logs or exports.
public struct DetectedEntity: Sendable, Identifiable {
    public let id: UUID
    public let type: EntityType
    public let value: String
    public let confidence: Double
    public let source: DetectionSource
    public var locus: Locus
    /// Assigned during the redaction pass, e.g. `[NAME_1]`.
    public var tokenLabel: String?
    /// What this detection is for: removing, or pointing at. Fixed by the rule that found it.
    public let disposition: Disposition
    /// Review toggle. Redaction reads THIS, not `disposition` — so a reader who does want a flagged
    /// code gone can switch it on and get it, and `disposition` stays a record of what was asked
    /// for rather than a second thing that has to agree.
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        type: EntityType,
        value: String,
        confidence: Double,
        source: DetectionSource,
        locus: Locus,
        tokenLabel: String? = nil,
        disposition: Disposition = .redact,
        isEnabled: Bool? = nil
    ) {
        self.id = id
        self.type = type
        self.value = value
        self.confidence = confidence
        self.source = source
        self.locus = locus
        self.tokenLabel = tokenLabel
        self.disposition = disposition
        // Default follows the disposition, so a flag rule cannot ship something that redacts anyway.
        // An explicit value still wins — that is the review toggle doing its job.
        self.isEnabled = isEnabled ?? (disposition == .redact)
    }
}

public extension DetectedEntity {
    var isTextLocus: Bool {
        if case .text = locus { return true }
        return false
    }

    /// Character offsets of a text-locus entity within `text`, or nil for image loci.
    func offsets(in text: String) -> (start: Int, length: Int)? {
        guard case let .text(range) = locus else { return nil }
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let end = text.distance(from: text.startIndex, to: range.upperBound)
        return (start, end - start)
    }
}

/// One OCR result: recognised text and its box in **pixel space, top-left origin**.
public struct OCRObservation: Sendable {
    public let text: String
    public let box: CGRect
    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

/// `CGImage` is effectively immutable but not `Sendable`; this wrapper lets it cross
/// actor/task boundaries with the detectors.
public struct SendableImage: @unchecked Sendable {
    public let cgImage: CGImage
    public init(_ cgImage: CGImage) { self.cgImage = cgImage }
}

/// Input handed to a detector.
public enum DetectionInput: Sendable {
    case text(String)
    case image(SendableImage, ocr: [OCRObservation])
}

/// JSON-serialisable view of a detection for reports and export. Carries the
/// token label and offsets — never used to persist the raw value beyond the session.
public struct EntityReport: Codable, Sendable, Equatable {
    public let type: String
    public let token: String?
    public let confidence: Double
    public let source: String
    public let start: Int
    public let length: Int

    public init(type: String, token: String?, confidence: Double, source: String, start: Int, length: Int) {
        self.type = type
        self.token = token
        self.confidence = confidence
        self.source = source
        self.start = start
        self.length = length
    }
}

/// Build the entity JSON report, in reading order.
public func entityReports(for entities: [DetectedEntity], in text: String) -> [EntityReport] {
    entities
        .compactMap { entity -> (EntityReport, Int)? in
            guard let offsets = entity.offsets(in: text) else { return nil }
            let report = EntityReport(
                type: entity.type.identifier,
                token: entity.tokenLabel,
                confidence: entity.confidence,
                source: entity.source.rawValue,
                start: offsets.start,
                length: offsets.length
            )
            return (report, offsets.start)
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
}
