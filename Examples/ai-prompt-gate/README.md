# Local prompt gate

This example scans typed prompt text before Claude Code receives it. It uses
`clipscrub --no-llm`, so the result comes from deterministic local rules.

It does not scan attachments, tool output or files a model reads later. Those paths need
separate controls.

> **Important:** This is an experimental integration example. It cannot prove that a prompt
> is safe to share. Detection can miss sensitive content. Claude Code and macOS can change hook
> behaviour. Review the script and test your installed setup before you use it with real information.

## Install for Claude Code

1. Put `clipscrub-prompt-gate.sh` somewhere readable and executable.
2. Replace `/absolute/path/to/clipscrub-prompt-gate.sh` in `claude.settings.json`.
3. Merge the `UserPromptSubmit` entry into `.claude/settings.json`.

The hook checks for any ClipScrub finding. It blocks a detected prompt. When ClipScrub also
redacts the finding, the sanitized text goes to the clipboard. Review it, then paste and submit
it yourself. A finding that stays unchanged is blocked without a clipboard copy.

## Failure behaviour

The hook blocks the original prompt if ClipScrub is absent, fails or cannot copy the
sanitized text. It resolves the CLI through `CLIPSCRUB_BIN`, then `PATH`, then the
installed ClipScrub app helper. A host timeout can let a prompt continue. This example is
for macOS because it uses `plutil` and `pbcopy`. Keep sensitive prompt controls under review.
