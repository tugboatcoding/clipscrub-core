# Contributing

Thanks for your interest in ClipScrub's engine and CLI.

Development happens in an internal repository. Releases land here as clean
snapshots, so the history is squashed.

- **Issues and discussion** are very welcome here. Bug reports, detection gaps and
  false-positive or false-negative examples are especially useful.
- **Pull requests** are reviewed here, then re-applied upstream by a maintainer.
  Your change ships back out in the next release snapshot rather than merging into
  this repo's history directly. We credit you in the release notes.

## Ground rules for the engine

Two rules keep the redaction provably local. A PR that breaks either will be
declined:

- **No third-party runtime dependencies.** Detection uses Apple frameworks only.
- **No network.** No outbound request, ever, anywhere in the engine or the CLI.

## Redaction safety

Redaction fails hard. If detection or flattening fails, emit nothing. Never fall
back to the original content, because that hands back the unredacted input as if it
were clean. In particular, never turn a detection failure into "found nothing" —
`try? … ?? []` on a redaction path is a data leak, since an error that should stop
the pipeline instead lets the raw text through. When you change detection, add a
`ClipscrubVerify` check or an XCTest alongside it.

Run `swift test` and `swift run ClipscrubVerify` before opening a PR.
