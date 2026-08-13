# ClipScrub — local PHI/PII redaction engine and CLI

Strip **protected health information (PHI)** and **personally identifiable
information (PII)** out of text, images and documents **on your own machine**.
No network. No account. Nothing you redact ever leaves your Mac.

This is the open engine (`ClipscrubKit`) and the `clipscrub` command-line tool
behind [ClipScrub](https://clipscrub.com), a native macOS app. They are open
source so you can read exactly how the redaction works and check the privacy
claim for yourself.

## Why this is open

ClipScrub does all of its work locally. That is easy to say and hard to trust,
so the proof is in the code, not the marketing:

- **No third-party runtime dependencies.** Detection uses only Apple system
  frameworks (Foundation, NaturalLanguage, Vision, CryptoKit and, on macOS 26,
  FoundationModels). Open `Package.swift` and you will find no remote packages.
- **No network code.** Search the sources. There is no `URLSession`, no socket
  and no outbound request anywhere in the engine or the CLI.

The redaction happens locally, always.

## The `clipscrub` CLI

`clipscrub` is a redaction gate you put in front of everything else. It redacts
first, then hands you the clean output. It is deliberately **not** an LLM or MCP
tool, because the whole point is to stop raw PHI and PII from reaching a cloud
model in the first place. It is also deliberately **not** an API right now,
because an API is easy to wire into an LLM that then ships PHI to the cloud —
the exact thing this exists to prevent.

```bash
swift build --product clipscrub          # or: swift run clipscrub …

echo "SSN 123-45-6789" | clipscrub        # text: stdin → stdout
pbpaste | clipscrub | pbcopy              # redact whatever is on the clipboard
clipscrub notes.docx                      # document → redacted plain text (stdout)
clipscrub --image in.png out.png          # image: file → file
clipscrub --image in.pdf out.pdf          # PDF → flattened redacted PDF
clipscrub --doc  in.docx out.docx         # rich text → same format, formatting kept
clipscrub --deid in.dcm out.dcm           # DICOM / EDF header de-identification
clipscrub --mode pseudonymise --report < notes.txt
```

- **Standard output is the redacted text and nothing else.** `--report` prints
  per-type counts as JSON to standard error, like `{"name": 1, "ssn": 1}`. It
  never prints the raw values.
- **Stable tokens.** The same input value always maps to the same token, so one
  person reads as the same token everywhere in a document. In
  `--mode pseudonymise` those tokens are keyed pseudonyms instead of `[NAME_1]`.
- **It fails hard, never open.** If detection or flattening fails, the tool outputs
  nothing rather than pass the original through. A failure can never leak PHI by
  falling back to the unredacted input.
- **Optional local log.** The CLI can keep a running log of what it redacted (the
  same counts `--report` prints, never the values). It is off by default, opt-in,
  written to a file on your Mac and never sent anywhere.
- `--no-llm` falls back to the deterministic rules only, for reproducible output.
  On macOS 26 with Apple Intelligence the CLI also runs an on-device model pass by
  default. Where that model is unavailable it is skipped, and redaction never
  depends on it.

## How detection works

The deterministic rules are the floor. The optional on-device model adds a pass on
top for PHI phrased in ways the fixed rules cannot predict.

1. **Data detectors** — Apple `NSDataDetector` for structured values (dates, phone
   numbers, addresses, URLs).
2. **Regex rules** — editable patterns in `Sources/ClipscrubKit/Resources/ruleset.json`
   for labelled and structured identifiers (SSN, MRN, `Age: 47` and so on).
3. **Name matching** — `NLTagger` for names in context, plus a bundled name list
   (`Resources/given-names.json`) for the standalone and all-caps names it misses.
4. **On-device model** (macOS 26, optional) — a semantic pass that catches PHI the
   fixed rules do not, phrased in ways a pattern cannot anticipate. It runs behind
   `#if canImport(FoundationModels)` and never gates the layers above it.

Overlapping matches are merged into non-overlapping spans, then replaced with
tokens (`[NAME_1]`) or stable keyed pseudonyms.

## Document and medical formats

- **Documents** — `.docx`, `.rtf`, `.html`, PDF and plain text. Rich text keeps its
  formatting. PDFs are flattened to a raster, so a box over the text does not leave
  the text still selectable underneath.
- **Medical files** — `--deid` de-identifies the header fields that carry PHI in
  **DICOM** and **EDF**, where a content scan can never reach it. v1 is honest about
  its limits: DICOM burned-in pixel PHI and UIDs are not modified.

## Build and test

Requires macOS 15 (Sequoia) or later and Swift 6 (Xcode 26 or the Command Line Tools).

```bash
swift build                     # engine + CLI
swift run ClipscrubVerify       # headless smoke checks, works with the Command Line Tools
swift test                      # full test suite
```

## Releases and verification

Each release is tagged here and cut by [the release workflow](.github/workflows/release.yml). The
`clipscrub` CLI attached to a release is built by that workflow, from this repo, at that tag, and
carries a build provenance attestation. So you can check the binary against the source without
trusting whoever handed it to you:

```bash
gh release download --repo tugboatcoding/clipscrub-core --pattern clipscrub-macos-universal.tar.gz
gh attestation verify clipscrub-macos-universal.tar.gz --repo tugboatcoding/clipscrub-core
tar -xzf clipscrub-macos-universal.tar.gz
```

Naming no tag takes the latest release, so those commands keep working as versions move.

The archive holds two things and they belong together. `ClipscrubKit_ClipscrubKit.bundle` carries
the ruleset and the name list, and the tool reads them from beside its own binary — move the binary
out on its own and it stops before it redacts anything.

The ClipScrub app is closed source, so its disk image is built and signed on a maintainer machine
and cannot be attested here. It gets a published checksum instead. `CHECKSUMS.txt` at the tip of
this repo carries the hash for the disk image live at the last publish, and each release repeats
the hash that was live when that release was cut:

```bash
shasum -a 256 ClipScrub.dmg
```

Building from source is always the third option, and needs no trust in either.

## Compliance

ClipScrub helps with the de-identification that **HIPAA**, **GDPR**, **CCPA** and
similar regimes require, by removing identifiers before data leaves your control.
It is a tool, not a guarantee. It does not certify compliance and it is not legal
advice — you own the decision about what counts as de-identified for your use.

## FAQ

**Is the whole app open source?** No. This repo is the redaction engine and the
CLI, the part that touches your data. The macOS app around it (screen capture,
recording, the review interface) is closed source.

**Does anything get sent anywhere?** No. There is no network code. The optional
usage log stays on your Mac.

**Can I add my own identifiers?** Yes. Edit `Resources/ruleset.json` for patterns
and `Resources/given-names.json` for names. Neither needs a code change.

**Does it run on Linux?** Not today. It is built on Apple frameworks (Vision,
NaturalLanguage, FoundationModels).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). For anything that leaks data, see
[SECURITY.md](SECURITY.md) instead of opening a public issue.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
