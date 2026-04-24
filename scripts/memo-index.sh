#!/usr/bin/env bash
# memo-index: generate coo/memo_index.json from coo/memos.md.
#
# Idempotent bash indexer per coo/memo_system_transition.md §3 Track 1.
# Parses every "## MEMO YYYY-MM-DD-NN — <subtitle>" header in the memo
# corpus, extracts metadata (status, supersedes) and body references,
# emits a JSON array sorted newest-first by id, and writes atomically
# to coo/memo_index.json. Diff-gated: no-op if the generated JSON
# matches the on-disk file byte-for-byte.
#
# Invoked at SessionStart (matcher: startup) from the dispatch chain,
# and runnable standalone for manual regeneration. Safe to run repeatedly.
#
# Output schema per entry (array-ordered newest-first):
#   {id, date, title, status, supersedes, supersedes_refs,
#    superseded_by, linked_issues, summary_one_line,
#    line_start, line_end}
#
# Note: the corpus contains duplicate memo IDs (three pairs as of
# 2026-04-24), so the index must be a JSON *array*, not an object
# keyed by id. line_start disambiguates duplicates.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

boot_log_record memo-index start

entries_file=""
_memo_index_cleanup() {
  local rc=$?
  if [ -n "$entries_file" ]; then
    rm -f "$entries_file" "${entries_file}.tmp" 2>/dev/null || true
  fi
  boot_log_record memo-index end $([ $rc -eq 0 ] && echo ok || echo fail) rc=$rc
  return $rc
}
trap _memo_index_cleanup EXIT

if [ -n "${COO_MEMORY_DIR:-}" ]; then
  MEM_REPO="$COO_MEMORY_DIR"
elif [ "$HOME" != "/home/user" ] && [ -d "$HOME/GitHub/vade-app/vade-coo-memory" ]; then
  MEM_REPO="$HOME/GitHub/vade-app/vade-coo-memory"
else
  MEM_REPO="/home/user/vade-coo-memory"
fi
MEMOS="$MEM_REPO/coo/memos.md"
INDEX="$MEM_REPO/coo/memo_index.json"

if [ ! -f "$MEMOS" ]; then
  echo "[vade-setup] memo-index: $MEMOS not found; skipping."
  exit 0
fi

if ! check_cmd jq; then
  echo "[vade-setup] memo-index: jq not on PATH; skipping." >&2
  exit 0
fi

total_lines=$(wc -l < "$MEMOS")

# Collect all memo header lines as "linenum:raw-header-text".
mapfile -t headers < <(grep -n '^## MEMO ' "$MEMOS" || true)

if [ "${#headers[@]}" -eq 0 ]; then
  echo "[vade-setup] memo-index: no memo headers found in $MEMOS; skipping." >&2
  exit 0
fi

entries_file="$(mktemp)"

parse_warnings=0

for i in "${!headers[@]}"; do
  raw="${headers[$i]}"
  line_start="${raw%%:*}"
  header_text="${raw#*:}"

  # Header format: "## MEMO YYYY-MM-DD-NN — <subtitle>"
  # The separator is an em-dash (U+2014) with surrounding spaces.
  if [[ "$header_text" =~ ^##[[:space:]]MEMO[[:space:]]([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2})[[:space:]]—[[:space:]](.+)$ ]]; then
    id="${BASH_REMATCH[1]}"
    subtitle="${BASH_REMATCH[2]}"
  else
    echo "[vade-setup] memo-index: WARN: could not parse header at L${line_start}: ${header_text}" >&2
    parse_warnings=$((parse_warnings + 1))
    continue
  fi
  date="${id:0:10}"

  # line_end = the line before the next header, or EOF for the last memo.
  if (( i + 1 < ${#headers[@]} )); then
    next_line="${headers[$((i + 1))]%%:*}"
    line_end=$((next_line - 1))
  else
    line_end="$total_lines"
  fi

  # Extract the memo's text slice for field parsing.
  body=$(sed -n "${line_start},${line_end}p" "$MEMOS")

  # Metadata fields. The metadata block is the run of **Key:** lines
  # immediately after the header; Supersedes content can be long but
  # is always single-line per the corpus convention.
  status=""
  supersedes=""
  while IFS= read -r mline; do
    if [[ "$mline" =~ ^\*\*Status:\*\*[[:space:]](.*)$ ]]; then
      status="${BASH_REMATCH[1]}"
    elif [[ "$mline" =~ ^\*\*Supersedes:\*\*[[:space:]](.*)$ ]]; then
      supersedes="${BASH_REMATCH[1]}"
    fi
  done <<< "$body"

  # linked_issues: bare "#N" references anywhere in the memo body.
  # Dedupe numerically; emit sorted ascending.
  linked_issues_json=$(
    { grep -oE '#[0-9]+' <<< "$body" || true; } |
    sed 's/^#//' |
    sort -nu |
    jq -Rn '[inputs | select(length > 0) | tonumber]'
  )

  # supersedes_refs: memo IDs mentioned in the raw Supersedes string.
  # Pattern matches YYYY-MM-DD-NN. De-duplicated; lexicographic sort.
  supersedes_refs_json=$(
    { grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}' <<< "$supersedes" || true; } |
    sort -u |
    jq -Rn '[inputs | select(length > 0)]'
  )

  jq -n \
    --arg id "$id" \
    --arg date "$date" \
    --arg title "$subtitle" \
    --arg status "$status" \
    --arg supersedes "$supersedes" \
    --argjson supersedes_refs "$supersedes_refs_json" \
    --argjson linked_issues "$linked_issues_json" \
    --arg summary_one_line "$subtitle" \
    --argjson line_start "$line_start" \
    --argjson line_end "$line_end" \
    '{
      id:               $id,
      date:             $date,
      title:            $title,
      status:           $status,
      supersedes:       $supersedes,
      supersedes_refs:  $supersedes_refs,
      superseded_by:    [],
      linked_issues:    $linked_issues,
      summary_one_line: $summary_one_line,
      line_start:       $line_start,
      line_end:         $line_end
    }' >> "$entries_file"
done

# Merge entries into an array, compute superseded_by by inverting
# supersedes_refs across the corpus, and sort newest-first.
# Tie-break on line_start so duplicate-id pairs have stable order
# (later-in-file wins, matching chronological intuition).
generated=$(
  jq -s '
    . as $all |
    map(
      . as $m |
      .superseded_by = ([$all[] | select(.supersedes_refs | index($m.id)) | .id] | unique)
    ) |
    sort_by([.id, .line_start]) |
    reverse
  ' "$entries_file"
)

count=$(jq 'length' <<< "$generated")
echo "[vade-setup] memo-index: parsed $count memos from $MEMOS (warnings: $parse_warnings)"

# Diff-gate: canonicalise both sides with `jq -S .` and compare.
new_canon=$(jq -S . <<< "$generated")
if [ -f "$INDEX" ] && existing_canon=$(jq -S . "$INDEX" 2>/dev/null); then
  if [ "$new_canon" = "$existing_canon" ]; then
    echo "[vade-setup] memo-index: $INDEX up-to-date; no write."
    exit 0
  fi
fi

# Atomic write. Pretty-print (default jq) for human readability; the
# canonical form above is used only for diff-gating.
tmp_out="${INDEX}.tmp"
jq . <<< "$generated" > "$tmp_out"
mv -f "$tmp_out" "$INDEX"
echo "[vade-setup] memo-index: wrote $INDEX ($count entries)"
