#!/usr/bin/env bash
# A UserPromptSubmit hook for Claude Code.
#
# It emits protocol JSON only. The prompt stays in standard input and shell memory. It is never
# placed in an argument, a file, stdout, stderr or a log. A changed prompt is copied for one reviewed
# paste because these hook APIs can block the original submission but cannot replace it inline.
set -uo pipefail

block() {
  printf '%s\n' '{"decision":"block","reason":"ClipScrub stopped this prompt. The sanitized text is on your clipboard when available.","suppressOriginalPrompt":true}'
  exit 0
}

prompt="$(/usr/bin/plutil -extract prompt raw -o - - 2>/dev/null)" || block

if [ -n "${CLIPSCRUB_BIN:-}" ] && [ -x "$CLIPSCRUB_BIN" ]; then
  clipscrub_bin="$CLIPSCRUB_BIN"
elif clipscrub_path="$(command -v clipscrub 2>/dev/null)" && [ -n "$clipscrub_path" ]; then
  clipscrub_bin="$clipscrub_path"
elif [ -x '/Applications/ClipScrub.app/Contents/Helpers/clipscrub' ]; then
  clipscrub_bin='/Applications/ClipScrub.app/Contents/Helpers/clipscrub'
else
  block
fi

check_status=0
printf '%s' "$prompt" | "$clipscrub_bin" --no-llm --check >/dev/null 2>/dev/null || check_status=$?

if [ "$check_status" = 0 ]; then
  exit 0
fi

if [ "$check_status" != 20 ]; then
  block
fi

sanitized="$(printf '%s' "$prompt" | "$clipscrub_bin" --no-llm 2>/dev/null)" || block

# A flagged finding can remain in output. Block it without copying the original prompt.
if [ "$sanitized" = "$prompt" ]; then
  block
fi

printf '%s' "$sanitized" | pbcopy >/dev/null 2>&1 || block
block
