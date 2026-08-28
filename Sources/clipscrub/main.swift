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
  clipscrub --check [<file>] [--no-llm]                    text → exit status only
  clipscrub --image <in.png|in.pdf> <out.png|out.pdf> […]  image/PDF: file → file (format from <out>)
  clipscrub --doc   <in.docx|in.rtf> <out>                 rich-text → same format, formatted
  clipscrub --deid  <in.dcm|in.edf> <out>                  DICOM/EDF header de-id

FLAGS
  <file>            a doc (docx/rtf/html/txt/…) to redact to plain text; omit to read stdin
  --image           treat input/output as an image or PDF (requires <in> <out>)
  --doc             re-export a redacted rich-text doc in its ORIGINAL format (keeps formatting)
  --deid            de-identify a DICOM (.dcm) or EDF (.edf) file's PHI header fields
  --mode <m>        redact (default) | pseudonymise (stable keyed tokens); text and docs only
  --flatten-only    PDF out: pixels only, no searchable text (see below)
  --no-llm          skip the on-device Apple Intelligence tier (deterministic only); text and docs
  --no-user-rules   ignore saved custom patterns
  --check           exit 20 when text has a finding, 0 when it has none; writes no output
  --report          print a JSON summary (per-type counts, no raw values) to stderr,
                    plus a line naming anything found and deliberately left in
  -h, --help        show this help

Runs the deterministic detection layers (SSN, names, dates, addresses, IDs,
faces, barcodes, …). Clinical codes are found but NOT removed: a CPT or a
diagnosis code is usually the reason a document is being shared, so taking it
out destroys the document. --report names anything left in this way.

On macOS 26 with Apple Intelligence available it ALSO runs
an on-device Foundation Models tier that catches contextual PHI the rules miss —
on by default. That tier's output can vary run to run, so pass --no-llm for
byte-stable, reproducible output in scripts. When the model is unavailable (older
macOS, Apple Intelligence off) the tier is skipped automatically. Images and PDFs
run the deterministic layers only. Output goes to stdout only; nothing leaves your
machine.

A PDF that arrives with a text layer keeps one. Every page is still rasterised, so
nothing sits under a redaction box, and the words that were not removed are written
back over their own pixels. The output stays searchable and the removed values are
gone from the file. A scanned PDF has no text to keep and comes back as pixels.
--flatten-only turns this off and emits pixels for every page.

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

func emitReport(_ entities: [DetectedEntity], flagged: [DetectedEntity] = [], enabled: Bool) {
    guard enabled else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    if let data = try? encoder.encode(entityCounts(entities)), let json = String(data: data, encoding: .utf8) {
        stderr(json)
    }
    // Say what stayed in. The JSON above counts what was REMOVED, so without this line a code left
    // in on purpose is indistinguishable from one that was never found — and the reader learns
    // which by sending a document that still has it.
    guard !flagged.isEmpty else { return }
    let summary = entityCounts(flagged)
        .sorted { $0.key < $1.key }
        .map { "\($0.key) \($0.value)" }
        .joined(separator: ", ")
    stderr("left in (found, not removed): \(summary)")
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
func textPipeline(noLLM: Bool, userRules: [UserRule]) throws -> RedactionPipeline {
    try noLLM ? .makeDefault(userRules: userRules) : .makeWithModel(userRules: userRules)
}

/// Custom patterns the user wrote in the app, read from the shared container.
///
/// A rule that will not compile is named on stderr rather than dropped quietly. The user wrote it
/// expecting those matches to go, and a pipe that silently keeps them looks exactly like a pipe that
/// removed them.
///
/// The app can only write to this directory on a signed build. On an unsigned local build it falls
/// back to its own container, which is not this path, so an empty list here is a real answer and not
/// something to warn about.
func loadUserRules(skip: Bool) -> [UserRule] {
    guard !skip else { return [] }
    let rules = UserRuleStore.load(in: UserRuleStore.directForCLI())
    // Compiling here and again inside the pipeline is deliberate. Asking which rules are broken
    // means compiling them, and the alternative is a factory that takes a prebuilt detector, which
    // would put the detector in every caller's signature to save a few microseconds on a handful of
    // patterns.
    let rejected = UserRuleDetector(rules: rules).rejected
    for bad in rejected {
        stderr("clipscrub: custom rule '\(bad.name)' was skipped — \(bad.reason)")
    }
    return rules
}

// MARK: - Parse

var isImage = false
var deid = false
var doc = false
var report = false
var noLLM = false
var noUserRules = false
var check = false
var flattenOnly = false
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
    case "--no-user-rules": noUserRules = true
    case "--check": check = true
    case "--flatten-only": flattenOnly = true
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

// One input mode at a time. Silently letting the first branch win made `--image --doc` do something
// nobody asked for.
let modeFlags = [("--image", isImage), ("--doc", doc), ("--deid", deid)].filter(\.1).map(\.0)
if modeFlags.count > 1 { die("\(modeFlags.joined(separator: " and ")) can't be combined") }

/// Refuse to write over the file being read. `Data.write` is not atomic by default, so a partial
/// write here would leave neither the original nor a complete result.
func checkedOutput(_ inputPath: String, _ outputPath: String) -> URL {
    let input = URL(fileURLWithPath: inputPath).standardizedFileURL
    let output = URL(fileURLWithPath: outputPath).standardizedFileURL
    if input == output { die("the output file must be different from the input") }
    return output
}

/// Write the finished artifact in one step, so a failure part way leaves no half-written file that
/// looks like a redacted one.
func writeOutput(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
}

// Before anything reads the shared container: an older build wrote to the unprefixed group id.
let adoption = CLIUsageLog.adoptLegacyContainer()
let legacyPath = CLIUsageLog.legacyDirectForCLI().path
for name in adoption.failed {
    stderr("clipscrub: could not copy '\(name)' out of \(legacyPath) — this run does not see what is in it")
}
for name in adoption.alreadyPresent {
    stderr("clipscrub: '\(name)' also exists in \(legacyPath) — this run used the newer copy. Delete that folder to stop this notice")
}

do {
    if deid {
        if check { die("--check supports text only") }
        guard positionals.count == 2 else { die("--deid needs <in.dcm|in.edf> <out>") }
        if mode != .redact { die("--deid blanks header fields; it has no --mode") }
        let inputURL = URL(fileURLWithPath: positionals[0])
        let outputURL = checkedOutput(positionals[0], positionals[1])
        guard let data = try? Data(contentsOf: inputURL) else { die("could not read \(positionals[0])") }
        // Extension first, then the bytes — clinical DICOM files often arrive with no extension at
        // all, so the name alone decides nothing.
        guard let format = FileDeidentifier.format(for: inputURL) ?? FileDeidentifier.detect(data) else {
            die("--deid supports DICOM (.dcm/.dicom) and EDF (.edf) files")
        }
        guard let result = FileDeidentifier.deidentify(data, format: format) else {
            die("\(format.rawValue) de-identification failed (unsupported file structure)")
        }
        try writeOutput(result.data, to: outputURL)
        for line in result.summary { stderr(line) }
        logCLIUsage(command: .deid, mode: mode, entities: [])
    } else if isImage {
        if check { die("--check supports text only") }
        guard positionals.count == 2 else { die("--image needs <in.png|in.pdf> <out.png|out.pdf>") }
        // Pseudonyms on this path would need a token per box in the image AND in the text layer, and
        // only the GUI builds that map today. Plain-redacting while accepting the flag would report a
        // mode it had not run.
        if mode != .redact { die("--mode pseudonymise works on text and documents, not images") }
        let inputURL = URL(fileURLWithPath: positionals[0])
        let outputURL = checkedOutput(positionals[0], positionals[1])

        // A PNG/JPG/… is one page; a PDF is many. DocumentDecoder handles both.
        let decodedPages: [DecodedPage]
        switch DocumentDecoder.decode(inputURL) {
        case .pages(let decoded): decodedPages = decoded
        case .text: die("that's a text document — redact it as text (omit --image)")
        case nil: die("could not read an image or PDF at \(positionals[0])")
        }

        let pipeline = try ImageRedactionPipeline.makeDefault(userRules: loadUserRules(skip: noUserRules))
        var redactedPages: [PDFAssembler.Page] = []
        var allRegions: [DetectedEntity] = []
        for page in decodedPages {
            let source = page.image.cgImage
            let (redacted, regions) = try await pipeline.redact(source)
            guard let output = redacted else { die("redaction failed") } // fail closed
            redactedPages.append(PDFAssembler.Page.make(
                flattened: output,
                rasterSize: CGSize(width: source.width, height: source.height),
                pageSize: page.pageSize,
                text: flattenOnly ? nil : page.text,
                regions: regions
            ))
            allRegions += regions
        }

        // The OUTPUT extension picks the format. Deciding from the input wrote PDF bytes into a file
        // named .png whenever a PDF went in.
        if outputURL.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFAssembler.pdfData(from: redactedPages) else { die("could not assemble the PDF") }
            try writeOutput(pdf, to: outputURL)
        } else if redactedPages.count > 1 {
            die("\(positionals[0]) has \(redactedPages.count) pages — give the output a .pdf name to keep them all")
        } else {
            guard let png = ImageRedactor().encodePNG(redactedPages[0].image) else { die("redaction failed") }
            try writeOutput(png, to: outputURL)
        }
        // Split the same way the text path does: the JSON counts what was covered, the extra line
        // names what was found and left visible. ImageRedactor draws boxes over enabled regions
        // only, so a flagged code stays readable in the output image and has to be said out loud.
        emitReport(allRegions.filter(\.isEnabled),
                   flagged: allRegions.filter { $0.disposition == .flag && !$0.isEnabled },
                   enabled: report)
        // What was covered, matching the text and doc paths. Logging every detection here would
        // count a code we deliberately left visible as one we removed.
        logCLIUsage(command: .image, mode: mode, entities: allRegions.filter(\.isEnabled))
    } else if doc {
        if check { die("--check supports text only") }
        // Rich-text (rtf/doc/docx/html/odt) → redact the identifier spans, keep the formatting.
        guard positionals.count == 2 else { die("--doc needs <in> <out>") }
        let inputURL = URL(fileURLWithPath: positionals[0])
        let outputURL = checkedOutput(positionals[0], positionals[1])
        guard let attributed = try? NSAttributedString(url: inputURL, options: [:], documentAttributes: nil) else {
            die("could not read a rich-text document at \(positionals[0])")
        }
        let result = try await textPipeline(noLLM: noLLM, userRules: loadUserRules(skip: noUserRules)).run(
            text: attributed.string, mode: mode, pseudonymiser: pseudonymiser(for: mode)
        )
        let redacted = AttributedRedactor.apply(result.entities, to: attributed)
        let data = try redacted.data(from: NSRange(location: 0, length: redacted.length),
                                     documentAttributes: [.documentType: documentType(for: inputURL)])
        try writeOutput(data, to: outputURL)
        emitReport(result.entities, flagged: result.flagged, enabled: report)
        logCLIUsage(command: .doc, mode: mode, entities: result.entities)
    } else {
        // Text: a document/plain-text file positional, else stdin.
        let text: String
        if let path = positionals.first {
            guard positionals.count == 1 else { die("too many arguments (one input file, or pipe via stdin)") }
            switch DocumentDecoder.decode(URL(fileURLWithPath: path)) {
            case .text(let decoded): text = decoded
            case .pages: die("that's an image/PDF — use --image")
            case nil: die("could not read \(path)")
            }
        } else {
            // Bare run on a terminal would block silently on stdin — show help instead.
            if isatty(STDIN_FILENO) == 1 { stderr(usage); exit(2) }
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let stdin = String(data: data, encoding: .utf8) else { die("input is not UTF-8 text") }
            text = stdin
        }
        let pipeline = try textPipeline(noLLM: noLLM, userRules: loadUserRules(skip: noUserRules))
        if check {
            let findings = try await pipeline.detect(text: text)
            exit(findings.isEmpty ? 0 : 20)
        }
        let result = try await pipeline.run(text: text, mode: mode, pseudonymiser: pseudonymiser(for: mode))
        FileHandle.standardOutput.write(Data(result.redactedText.utf8))
        emitReport(result.entities, flagged: result.flagged, enabled: report)
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
