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

# Semantic form: --semantic <query>
# Semantic search requires the Mem0 MCP; bash cannot invoke MCP tools.
# The slash command markdown (/memo-query) owns the semantic dispatch —
# when it sees --semantic, it skips bash output and does the MCP work
# directly. We exit silently here so the eager `!bash` expansion in the
# command file doesn't emit stray keyword-match output for semantic args.
if [[ "$raw" =~ ^--semantic($|[[:space:]]|=) ]]; then
  exit 0
fi

if [ -z "$raw" ]; then
  echo "=== 10 most recent memos (from $(basename "$INDEX")) ==="
  echo
  jq '.[:10]' "$INDEX" | render_entries
  echo
  echo "Tip: /memo-query <id>  |  /memo-query <keyword>  |  /memo-query YYYY-MM-DD..YYYY-MM-DD"
  exit 0
fi

# Render-ids form: --render-ids <csv>
# Takes a comma-separated list of memo IDs and renders matching index
# entries using the same template as other modes. Callers (e.g. the
# memo-search skill, which pulls ids from Mem0 semantic search) use
# this to keep output shape consistent across all query modes.
# Order is preserved from the input list — if the caller's ranking
# matters (Mem0 rank), the list order is what gets printed.
if [[ "$raw" =~ ^--render-ids($|[[:space:]]|=) ]]; then
  ids_raw="${raw#--render-ids}"
  # Strip the leading space-or-equals separator, then trim.
  ids_raw="${ids_raw# }"
  ids_raw="${ids_raw#=}"
  ids_raw="${ids_raw#"${ids_raw%%[![:space:]]*}"}"
  ids_raw="${ids_raw%"${ids_raw##*[![:space:]]}"}"
  if [ -z "$ids_raw" ]; then
    echo "memo-query: --render-ids requires a comma-separated memo-id list" >&2
    exit 2
  fi
  # Convert "a,b,c" → JSON array, trimming whitespace per element.
  ids_json=$(printf '%s' "$ids_raw" | jq -R '
    split(",") | map(sub("^\\s+"; "") | sub("\\s+$"; "")) | map(select(length > 0))
  ')
  # For each id, collect all matching entries from the index (there
  # are known duplicate ids — same id, different line_start — and the
  # caller wants to see every physical memo). Preserve caller order.
  matches=$(jq --argjson ids "$ids_json" '
    . as $idx |
    $ids | map(. as $id | $idx | map(select(.id == $id))) | add // []
  ' "$INDEX")
  count=$(jq 'length' <<<"$matches")
  if [ "$count" -eq 0 ]; then
    echo "memo-query: no matching entries in $(basename "$INDEX") for ids: $ids_raw"
    exit 0
  fi
  # No header here — the semantic-search caller wraps with its own
  # header so it can cite the NL query. Callers that want a header
  # can prepend their own.
  render_entries <<<"$matches"
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
