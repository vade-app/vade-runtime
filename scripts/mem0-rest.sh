#!/usr/bin/env bash
# mem0-rest: REST fallback for the Mem0 Platform when the MCP transport
# is degraded or unavailable in this session.
#
# The Mem0 MCP client does a single OAuth discovery call at session init
# and disables the server if it gets any 5xx (including the intermittent
# Cloudflare-edge "DNS cache overflow" 503 observed 2026-04-24). Once
# the server is marked dead for the session, Claude Code on the web has
# no way to re-init (no `/mcp` command). This script gives memo-sync
# and memo-search a break-glass path that doesn't go through MCP at all:
# Mem0 Platform's REST API + a $MEM0_API_KEY.
#
# Same token → different wire. Mirrors the MEMO 2026-04-23-02 pattern
# for github-coo MCP degradation.
#
# Scope: only the operations memo-sync and memo-search need — search
# with metadata filter, list, add with infer=false, delete by id. Not a
# general-purpose Mem0 client. Output is Mem0's raw JSON; callers jq it.
#
# Usage:
#   mem0-rest.sh ping
#       Confirm $MEM0_API_KEY works by fetching the /v1/memories/ root.
#       Exits 0 on 2xx; non-zero otherwise.
#   mem0-rest.sh list-memo-pointers
#       Return all memo_pointer records under user_id=ven, created_by=coo.
#   mem0-rest.sh search-memo-pointers "<query>" [top_k=10]
#       Semantic search scoped to memo_pointer records.
#   mem0-rest.sh add-memo-pointer <memo_id> <line_start> <line_end> \
#                                 <date> <status> <supersedes|null> \
#                                 <text> [source_session]
#       Add one memo_pointer record with infer=false.
#   mem0-rest.sh delete-memory <mem0_id>
#       Delete a single record by Mem0 id.
#
# Exit codes:
#   0  success
#   2  env/usage error
#   3  HTTP non-2xx from Mem0 (body printed to stdout, headers to stderr)
#
# Env:
#   MEM0_API_KEY   required; Mem0 Platform API key (prefix `m0-`).
#   MEM0_BASE_URL  optional override; default https://api.mem0.ai.
set -euo pipefail

BASE="${MEM0_BASE_URL:-https://api.mem0.ai}"
API_KEY="${MEM0_API_KEY:-}"

die() { echo "mem0-rest: $*" >&2; exit "${2:-2}"; }

usage() {
  cat <<'EOF'
mem0-rest: REST fallback for the Mem0 Platform.

Usage:
  mem0-rest.sh ping
      Confirm $MEM0_API_KEY works.
  mem0-rest.sh list-memo-pointers
      Return all memo_pointer records (user_id=ven, created_by=coo).
  mem0-rest.sh search-memo-pointers "<query>" [top_k=10]
      Semantic search scoped to memo_pointer.
  mem0-rest.sh add-memo-pointer <memo_id> <line_start> <line_end>
                                <date> <status> <supersedes|null>
                                <text> [source_session]
      Add one record with infer=false.
  mem0-rest.sh delete-memory <mem0_id>
      Delete a single record by Mem0 id.

Env:
  MEM0_API_KEY   required; Mem0 Platform API key (prefix m0-).
  MEM0_BASE_URL  optional override; default https://api.mem0.ai.

Exit codes:
  0 success   2 env/usage error   3 HTTP non-2xx from Mem0
EOF
}

# Handle --help BEFORE the env check so `--help` works without a key.
case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  "") usage; exit 2 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  die "jq is required on PATH"
fi
if ! command -v curl >/dev/null 2>&1; then
  die "curl is required on PATH"
fi
if [ -z "$API_KEY" ]; then
  cat >&2 <<'EOF'
mem0-rest: MEM0_API_KEY is not set.

  Generate a key at https://app.mem0.ai/dashboard/api-keys and add it
  to the env block of ~/.claude/settings.json, e.g.:

    "env": {
      "MEM0_API_KEY": "m0-..."
    }

  Then resume this session for Claude Code to pick it up.
EOF
  exit 2
fi

# The metadata filter that scopes all reads and diffs to memo_pointer
# records authored by the COO under user_id=ven.
FILTER_MEMO_POINTER='{"AND":[{"user_id":"ven"},{"metadata":{"created_by":"coo"}},{"metadata":{"memory_type":"memo_pointer"}}]}'

# Wrapper around curl that captures status, headers, and body separately;
# prints the body on stdout and fails with exit 3 on non-2xx.
# Args: METHOD URL [DATA]
http_call() {
  local method="$1" url="$2" data="${3:-}"
  local tmp_body tmp_status
  tmp_body=$(mktemp); tmp_status=$(mktemp)
  local -a curl_args=(-sS -X "$method" -o "$tmp_body" -w '%{http_code}' \
    -H "Authorization: Token $API_KEY" -H "Accept: application/json" --max-time 30)
  if [ -n "$data" ]; then
    curl_args+=(-H "Content-Type: application/json" --data "$data")
  fi
  curl "${curl_args[@]}" "$url" >"$tmp_status" 2>/dev/null || true
  local code; code=$(cat "$tmp_status"); rm -f "$tmp_status"
  cat "$tmp_body"; rm -f "$tmp_body"
  case "$code" in
    2??) return 0 ;;
    *) echo "mem0-rest: HTTP $code on $method $url" >&2; return 3 ;;
  esac
}

cmd="${1:-}"; shift || true

case "$cmd" in
  ping)
    # A cheap reachability + auth check. The v1 memories list endpoint
    # accepts empty body and returns paginated memories. A 2xx confirms
    # the key is valid and the REST transport is healthy.
    http_call GET "$BASE/v1/memories/?user_id=ven&page=1&page_size=1"
    ;;

  list-memo-pointers)
    body=$(jq -n --argjson f "$FILTER_MEMO_POINTER" '{filters: $f}')
    http_call POST "$BASE/v2/memories/" "$body"
    ;;

  search-memo-pointers)
    q="${1:-}"; top_k="${2:-10}"
    [ -n "$q" ] || die "search-memo-pointers: missing <query>"
    [[ "$top_k" =~ ^[0-9]+$ ]] || die "search-memo-pointers: top_k must be numeric"
    body=$(jq -n --arg q "$q" --argjson tk "$top_k" --argjson f "$FILTER_MEMO_POINTER" \
      '{query: $q, filters: $f, top_k: $tk}')
    http_call POST "$BASE/v2/memories/search/" "$body"
    ;;

  add-memo-pointer)
    [ "$#" -ge 7 ] || die "add-memo-pointer: need 7-8 args (see --help)"
    memo_id="$1"; line_start="$2"; line_end="$3"; date_s="$4"
    status_s="$5"; supersedes_raw="$6"; text="$7"; run_id="${8:-unknown}"
    [[ "$line_start" =~ ^[0-9]+$ ]] || die "line_start must be numeric"
    [[ "$line_end" =~ ^[0-9]+$ ]] || die "line_end must be numeric"
    # supersedes: literal "null" or empty → JSON null; otherwise a string.
    if [ "$supersedes_raw" = "null" ] || [ -z "$supersedes_raw" ]; then
      sup_arg='null'
    else
      sup_arg=$(jq -n --arg s "$supersedes_raw" '$s')
    fi
    body=$(jq -n \
      --arg text "$text" \
      --arg memo_id "$memo_id" \
      --argjson ls "$line_start" --argjson le "$line_end" \
      --arg date "$date_s" --arg status "$status_s" \
      --argjson supersedes "$sup_arg" \
      --arg run_id "$run_id" \
      '{
        messages: [{role: "user", content: $text}],
        user_id: "ven",
        infer: false,
        metadata: {
          memory_type: "memo_pointer",
          memo_id: $memo_id,
          line_start: $ls,
          line_end: $le,
          date: $date,
          status: $status,
          supersedes: $supersedes,
          created_by: "coo",
          retention: "durable",
          source_session: $run_id
        }
      }')
    http_call POST "$BASE/v1/memories/" "$body"
    ;;

  delete-memory)
    mem0_id="${1:-}"
    [ -n "$mem0_id" ] || die "delete-memory: missing <mem0_id>"
    http_call DELETE "$BASE/v1/memories/$mem0_id/"
    ;;

  -h|--help|help) usage; exit 0 ;;
  *)
    die "unknown command: $cmd  (try: mem0-rest.sh --help)"
    ;;
esac
