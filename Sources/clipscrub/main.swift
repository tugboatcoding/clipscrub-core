import AppKit
import ClipscrubKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

// clipscrub — a local redaction gate for scripts & pipes. Text: stdin → stdout.
// Image: file → file. Reuses ClipscrubKit's deterministic layers; no network, no
// third-party deps. Redact FIRST, then forward the clean output — never hand raw
// data to a cloud LLM.

let usage = """
clipscrub — redact PHI/PII locally, on-device (no network).

USAGE
  clipscrub [<file>] [--mode …] [--report]                 text/doc → stdout (redacted text)
  clipscrub --image <in.png|in.pdf> <out.png|out.pdf> […]  image/PDF: file → file
  clipscrub --doc   <in.docx|in.rtf> <out>                 rich-text → same format, formatted
  clipscrub --deid  <in.dcm|in.edf> <out>                  DICOM/EDF header de-id

FLAGS
  <file>            a doc (docx/rtf/html/txt/…) to redact to plain text; omit to read stdin
  --image           treat input/output as an image or PDF (requires <in> <out>)
  --doc             re-export a redacted rich-text doc in its ORIGINAL format (keeps formatting)
  --deid            de-identify a DICOM (.dcm) or EDF (.edf) file's PHI header fields
  --mode <m>        redact (default) | pseudonymise (stable keyed tokens)
  --no-llm          skip the on-device Apple Intelligence tier (deterministic only)
  --report          print a JSON summary (per-type counts, no raw values) to stderr
  -h, --help        show this help

Runs the deterministic detection layers (SSN, names, dates, addresses, IDs,
faces, barcodes, …). On macOS 26 with Apple Intelligence available it ALSO runs
an on-device Foundation Models tier that catches contextual PHI the rules miss —
on by default. That tier's output can vary run to run, so pass --no-llm for
byte-stable, reproducible output in scripts. When the model is unavailable (older
macOS, Apple Intelligence off) the tier is skipped automatically. Output goes to
stdout only; nothing leaves your machine.

ClipScrub is a tool, not a compliance guarantee. Review output before sharing.
"""

func stderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Fail closed: message to stderr, non-zero exit, nothing on stdout.
func die(_ message: String) -> Never {
    stderr("clipscrub: " + message)
    exit(1)
}

func emitReport(_ entities: [DetectedEntity], enabled: Bool) {
    guard enabled else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    if let data = try? encoder.encode(entityCounts(entities)), let json = String(data: data, encoding: .utf8) {
        stderr(json)
    }
}

/// Opt-in, metadata-only usage log. A host app (an app embedding ClipscrubKit, such as the
/// ClipScrub app) can surface it. Records per-type COUNTS only — never a raw value, never the
/// output. No-ops unless a host app wrote an enabled config into the shared container, so an
/// untouched CLI leaves zero footprint. Must never affect the pipe: all errors are swallowed
/// and nothing is written to stdout.
func logCLIUsage(command: CLICommandKind, mode: OutputMode, entities: [DetectedEntity]) {
    let directory = CLIUsageLog.directForCLI()
    guard let config = CLIUsageLog.loadConfig(in: directory), config.loggingEnabled else { return }
    let record = CLIUsageRecord(
        timestamp: Date(), mode: mode, command: command, entityCounts: entityCounts(entities)
    )
    try? CLIUsageLog.append(record, in: directory)
}

func pseudonymiser(for mode: OutputMode) -> Pseudonymiser? {
    guard mode == .pseudonymise else { return nil }
    if let stored = try? KeychainKeyStore().key(for: "pseudonym-hmac") {
        return Pseudonymiser(key: stored)
    }
    stderr("clipscrub: warning — Keychain unavailable; pseudonyms are not stable this run.")
    return Pseudonymiser(key: SymmetricKey(size: .bits256))
}

/// Text/doc pipeline. Runs the Foundation Models tier by default when available; `--no-llm` forces
/// deterministic-only (fast + reproducible). With no model available, `makeWithModel` == `makeDefault`.
func textPipeline(noLLM: Bool) throws -> RedactionPipeline {
    try noLLM ? .makeDefault() : .makeWithModel()
}

// MARK: - Parse

var isImage = false
var deid = false
var doc = false
var report = false
var noLLM = false
var mode: OutputMode = .redact
var positionals: [String] = []

var arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < arguments.count {
    let arg = arguments[index]
    switch arg {
    case "-h", "--help": print(usage); exit(0)
    case "--image": isImage = true
    case "--deid": deid = true
    case "--doc": doc = true
    case "--no-llm": noLLM = true
    case "--report": report = true
    case "--mode":
        index += 1
        guard index < arguments.count else { die("--mode needs a value (redact|pseudonymise)") }
        guard let parsed = OutputMode(rawValue: arguments[index]) else {
            die("unknown mode '\(arguments[index])' (use redact|pseudonymise)")
        }
        mode = parsed
    default:
        if arg.hasPrefix("-") { die("unknown flag '\(arg)' (see --help)") }
        positionals.append(arg)
    }
    index += 1
}

// MARK: - Run

do {
    if deid {
        guard positionals.count == 2 else { die("--deid needs <in.dcm|in.edf> <out>") }
        let inputURL = URL(fileURLWithPath: positionals[0])
        let outputURL = URL(fileURLWithPath: positionals[1])
        guard let format = FileDeidentifier.format(for: inputURL) else {
            die("--deid supports .dcm/.dicom and .edf files")
        }
        guard let data = try? Data(contentsOf: inputURL) else { die("could not read \(positionals[0])") }
        guard let result = FileDeidentifier.deidentify(data, format: format) else {
            die("\(format.rawValue) de-identification failed (unsupported file structure)")
        }
        try result.data.write(to: outputURL)
        for line in result.summary { stderr(line) }
        logCLIUsage(command: .deid, mode: mode, entities: [])
    } else if isImage {
        guard positionals.count == 2 else { die("--image needs <in.png|in.pdf> <out.png|out.pdf>") }
        let inputURL = URL(fileURLWithPath: positionals[0])
        let outputURL = URL(fileURLWithPath: positionals[1])

        // A PNG/JPG/… is one page; a PDF is many. DocumentDecoder handles both.
        let pages: [CGImage]
        switch DocumentDecoder.decode(inputURL) {
        case .images(let decoded): pages = decoded.map(\.cgImage)
        case .text: die("that's a text document — redact it as text (omit --image)")
        case nil: die("could not read an image or PDF at \(positionals[0])")
        }

        let pipeline = try ImageRedactionPipeline.makeDefault()
        var redactedPages: [CGImage] = []
        var allRegions: [DetectedEntity] = []
        for page in pages {
            let (redacted, regions) = try await pipeline.redact(page)
            guard let output = redacted else { die("redaction failed") } // fail closed
            redactedPages.append(output)
            allRegions += regions
        }

        if inputURL.pathExtension.lowercased() == "pdf" || redactedPages.count > 1 {
            guard let pdf = PDFAssembler.pdfData(from: redactedPages) else { die("could not assemble the PDF") }
            try pdf.write(to: outputURL)
        } else {
            guard let png = ImageRedactor().encodePNG(redactedPages[0]) else { die("redaction failed") }
            try png.write(to: outputURL)
        }
        emitReport(allRegions, enabled: report)
        logCLIUsage(command: .image, mode: mode, entities: allRegions)
    } else if doc {
        // Rich-text (rtf/doc/docx/html/odt) → redact the identifier spans, keep the formatting.
        guard positionals.count == 2 else { die("--doc needs <in> <out>") }
        let inputURL = URL(fileURLWithPath: positionals[0])
        let outputURL = URL(fileURLWithPath: positionals[1])
        guard let attributed = try? NSAttributedString(url: inputURL, options: [:], documentAttributes: nil) else {
            die("could not read a rich-text document at \(positionals[0])")
        }
        let result = try await textPipeline(noLLM: noLLM).run(
            text: attributed.string, mode: mode, pseudonymiser: pseudonymiser(for: mode)
        )
        let redacted = AttributedRedactor.apply(result.entities, to: attributed)
        let data = try redacted.data(from: NSRange(location: 0, length: redacted.length),
                                     documentAttributes: [.documentType: documentType(for: inputURL)])
        try data.write(to: outputURL)
        emitReport(result.entities, enabled: report)
        logCLIUsage(command: .doc, mode: mode, entities: result.entities)
    } else {
        // Text: a document/plain-text file positional, else stdin.
        let text: String
        if let path = positionals.first {
            guard positionals.count == 1 else { die("too many arguments (one input file, or pipe via stdin)") }
            switch DocumentDecoder.decode(URL(fileURLWithPath: path)) {
            case .text(let decoded): text = decoded
            case .images: die("that's an image/PDF — use --image")
            case nil: die("could not read \(path)")
            }
        } else {
            // Bare run on a terminal would block silently on stdin — show help instead.
            if isatty(STDIN_FILENO) == 1 { stderr(usage); exit(2) }
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let stdin = String(data: data, encoding: .utf8) else { die("input is not UTF-8 text") }
            text = stdin
        }
        let result = try await textPipeline(noLLM: noLLM).run(
            text: text, mode: mode, pseudonymiser: pseudonymiser(for: mode)
        )
        FileHandle.standardOutput.write(Data(result.redactedText.utf8))
        emitReport(result.entities, enabled: report)
        logCLIUsage(command: .text, mode: mode, entities: result.entities)
    }
} catch {
    die("\(error)") // fail closed — nothing was written to stdout
}

/// Map a rich-text file extension to the AppKit document type for re-export.
func documentType(for url: URL) -> NSAttributedString.DocumentType {
    switch url.pathExtension.lowercased() {
    case "docx": return .officeOpenXML
    case "doc": return .docFormat
    case "html", "htm": return .html
    case "odt": return .openDocument
    default: return .rtf
    }
}
