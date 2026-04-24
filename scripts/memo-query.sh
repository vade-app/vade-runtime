#!/usr/bin/env bash
# memo-query: query coo/memo_index.json for memos by ID, keyword, or date range.
#
# Companion to vade-runtime/scripts/memo-index.sh (which produces the
# index this script reads). Implements Track 2 of the memo-system
# transition ratified in MEMO 2026-04-24-03.
#
# Usage: memo-query.sh [query]
#   query forms:
#     YYYY-MM-DD-NN          -> return the single matching memo + sed hint
#     YYYY-MM-DD..YYYY-MM-DD -> return all memos in range, newest-first
#     <keyword>              -> case-insensitive substring match on title +
#                               summary_one_line, newest-first
#     (empty)                -> print the 10 most recent memos
#
# Exit codes: 0 on any successful query (including zero matches); non-zero
# only on environment errors (missing index, missing jq). Zero matches
# prints a one-liner explaining the empty result.
#
# Invoked from ~/.claude/commands/memo-query.md as:
#   !bash /home/user/vade-runtime/scripts/memo-query.sh "$ARGUMENTS"

set -euo pipefail

if [ -n "${COO_MEMORY_DIR:-}" ]; then
  MEM_REPO="$COO_MEMORY_DIR"
elif [ "$HOME" != "/home/user" ] && [ -d "$HOME/GitHub/vade-app/vade-coo-memory" ]; then
  MEM_REPO="$HOME/GitHub/vade-app/vade-coo-memory"
else
  MEM_REPO="/home/user/vade-coo-memory"
fi
INDEX="$MEM_REPO/coo/memo_index.json"
MEMOS_REL="coo/memos.md"
MEMOS_ABS="$MEM_REPO/$MEMOS_REL"

if ! command -v jq >/dev/null 2>&1; then
  echo "memo-query: jq not on PATH; cannot run." >&2
  exit 2
fi

if [ ! -f "$INDEX" ]; then
  cat <<EOF
memo-query: index not found at $INDEX
Regenerate with:
  bash /home/user/vade-runtime/scripts/memo-index.sh
EOF
  exit 2
fi

# Trim whitespace from the raw argument string (Claude Code passes the
# full $ARGUMENTS as a single positional).
raw="${1:-}"
raw="${raw#"${raw%%[![:space:]]*}"}"
raw="${raw%"${raw##*[![:space:]]}"}"

# Render a list of index entries as a compact human-readable block.
# Reads entries on stdin as a JSON array; emits one entry per three lines
# (header, one-liner, body-hint) separated by blank lines.
render_entries() {
  jq -r --arg memos "$MEMOS_REL" '
    .[] |
    "\(.id) (\(.date)) [\(.status)]  L\(.line_start)-\(.line_end)\n" +
    "  \(.summary_one_line)\n" +
    "  body: sed -n \(.line_start),\(.line_end)p " + $memos
  '
}

if [ -z "$raw" ]; then
  echo "=== 10 most recent memos (from $(basename "$INDEX")) ==="
  echo
  jq '.[:10]' "$INDEX" | render_entries
  echo
  echo "Tip: /memo-query <id>  |  /memo-query <keyword>  |  /memo-query YYYY-MM-DD..YYYY-MM-DD"
  exit 0
fi

# Memo-ID form: exact YYYY-MM-DD-NN.
if [[ "$raw" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
  # The corpus contains duplicate IDs (three pairs as of 2026-04-24);
  # the index disambiguates by line_start. Return every match.
  matches=$(jq --arg id "$raw" '[.[] | select(.id == $id)]' "$INDEX")
  count=$(jq 'length' <<<"$matches")
  if [ "$count" -eq 0 ]; then
    echo "memo-query: no memo with id '$raw' in $INDEX"
    exit 0
  fi
  if [ "$count" -gt 1 ]; then
    echo "=== $count entries for id $raw (duplicate-id disambiguated by line_start) ==="
  else
    echo "=== memo $raw ==="
  fi
  echo
  render_entries <<<"$matches"
  exit 0
fi

# Date-range form: YYYY-MM-DD..YYYY-MM-DD (inclusive both ends).
if [[ "$raw" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})\.\.([0-9]{4}-[0-9]{2}-[0-9]{2})$ ]]; then
  from="${BASH_REMATCH[1]}"
  to="${BASH_REMATCH[2]}"
  if [[ "$from" > "$to" ]]; then
    # Swap so either order works.
    tmp="$from"; from="$to"; to="$tmp"
  fi
  matches=$(jq --arg from "$from" --arg to "$to" \
    '[.[] | select(.date >= $from and .date <= $to)]' "$INDEX")
  count=$(jq 'length' <<<"$matches")
  echo "=== $count memos in $from..$to (newest-first) ==="
  echo
  if [ "$count" -gt 0 ]; then
    render_entries <<<"$matches"
  fi
  exit 0
fi

# Default: keyword substring match on title + summary_one_line (case-insensitive).
# Escape characters that jq's ascii_downcase + contains treats specially:
# jq `contains` takes a literal substring, so we pass the lowercased query
# via --arg (no regex involved); no escaping needed.
q_lower=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
matches=$(jq --arg q "$q_lower" '
  [.[] | select(
    (.title | ascii_downcase | contains($q)) or
    (.summary_one_line | ascii_downcase | contains($q))
  )]
' "$INDEX")
count=$(jq 'length' <<<"$matches")
echo "=== $count memos matching \"$raw\" (case-insensitive; title + summary) ==="
echo
if [ "$count" -gt 0 ]; then
  render_entries <<<"$matches"
fi
