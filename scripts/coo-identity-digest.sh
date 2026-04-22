#!/usr/bin/env bash
# COO identity digest for cloud Claude Code sessions.
#
# Prints the vade-coo-memory boot instructions (CLAUDE.md) and the
# latest memo header(s) so the identity reading order lands in the
# session's context on startup, rather than requiring a manual read
# pass. Called from the SessionStart: startup hook after
# coo-bootstrap.sh.
#
# No-op if vade-coo-memory is not checked out at the expected path.
# Output is reminder-only — it does not load Mem0, does not commit
# files, does not fail the session if the repo is missing.
set -euo pipefail

MEM_REPO="${COO_MEMORY_DIR:-/home/user/vade-coo-memory}"
CLAUDE_MD="$MEM_REPO/CLAUDE.md"
MEMOS="$MEM_REPO/coo/memos.md"

if [ ! -f "$CLAUDE_MD" ]; then
  echo "[vade-setup] coo-identity-digest: $CLAUDE_MD not found; skipping."
  exit 0
fi

echo "───────────────────────────────────────────────────────────────"
echo "COO identity boot (vade-coo-memory/CLAUDE.md)"
echo "───────────────────────────────────────────────────────────────"
cat "$CLAUDE_MD"

if [ -f "$MEMOS" ]; then
  echo ""
  echo "───────────────────────────────────────────────────────────────"
  echo "Latest memo headers (newest first; see coo/memos.md for bodies)"
  echo "───────────────────────────────────────────────────────────────"
  # Emit the last three memo headers (lines starting with '## MEMO ').
  # Case-law is read bottom-up; grep -n + tail gives the tail, then we
  # format as a short list.
  grep -n '^## MEMO ' "$MEMOS" | tail -n 3 | awk -F: '{
    line=$1
    sub(/^[^:]+:/, "", $0)
    header=$0
    sub(/^## /, "", header)
    printf "  L%-5s %s\n", line, header
  }'
  echo ""
  echo "Full file: $MEMOS"
fi

echo "───────────────────────────────────────────────────────────────"
