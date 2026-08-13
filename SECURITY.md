# Security policy

ClipScrub exists to keep PHI and PII from leaking. A bug that makes it leak is
the worst kind of bug it can have. If you find one, please tell us privately
first so a fix can ship before the details are public.

## What counts

A vulnerability here is a failure of the redaction mechanism, not of detection
coverage:

- Redaction that passes the original content through when it should have failed
  hard (a fail-open path).
- Content that was redacted but is still recoverable from the output, like text
  extractable under a redaction box or values surviving in file metadata.
- Raw values appearing anywhere other than the redacted output itself — in
  `--report`, in the usage log or in an error message.
- Any code path that sends data off the machine.

## What does not count

A detection miss is a quality issue, not a vulnerability. If the rules or the
model fail to flag an identifier in the first place — a name, an age, an
unusual MRN format — nothing failed mechanically. That is the accuracy limit
the README describes, and no detector catches everything. Report those as
regular issues, ideally with an example. They are genuinely useful and we do
fix them, just in the open.

## How to report

- Preferred: [GitHub private vulnerability reporting](https://github.com/tugboatcoding/clipscrub-core/security/advisories/new).
- Or email [hello@clipscrub.com](mailto:hello@clipscrub.com) with `SECURITY` in
  the subject.

Include the input that triggers it and what leaked. Please do not open a public
issue for a leak until a fix is out.

## What to expect

- We aim to acknowledge your report within 3 business days.
- For anything that leaks data, we aim to ship a fix or share a concrete plan
  within 30 days.
- Credit in the release notes if you want it.

These are targets, not guarantees. This is how we handle reports — it is not a
warranty or a service commitment, and the software is provided as is under the
[LICENSE](LICENSE).

## Supported versions

Only the latest release gets security fixes.
