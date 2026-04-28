#!/usr/bin/env bash
# test-issue-comments: smoke-test scripts/issue-comments.sh.
#
# Strategy: install a mock `gh` binary that returns a canned JSON
# array for the `api repos/.../issues/N/comments` call, then assert
# the wrapper's outputs (default projection, --full passthrough,
# --limit, --max-bytes truncation, footer messaging).
#
# Run: bash scripts/ci/test-issue-comments.sh
# Exit: 0 if all assertions pass, non-zero otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/../issue-comments.sh"

[ -x "$WRAPPER" ] || { echo "FAIL: wrapper not executable at $WRAPPER"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Fixture: 5 comments, mixed authors, varying body lengths. Two have
# reactions; one has multi-line body to verify newline collapsing.
cat > "$WORK/fixture.json" <<'EOF'
[
  {
    "id": 1001,
    "user": {"login": "alice"},
    "created_at": "2026-04-20T10:00:00Z",
    "body": "First comment. Short.",
    "reactions": {"+1": 2, "heart": 1, "rocket": 0}
  },
  {
    "id": 1002,
    "user": {"login": "bob"},
    "created_at": "2026-04-21T11:00:00Z",
    "body": "Second comment with a very very very very very very very very very very very very very very very very very long body that exceeds 120 chars by a comfortable margin so we can verify the truncation suffix.",
    "reactions": {}
  },
  {
    "id": 1003,
    "user": {"login": "alice"},
    "created_at": "2026-04-22T12:00:00Z",
    "body": "Multi\nline\nbody\nshould\ncollapse",
    "reactions": {"laugh": 3}
  },
  {
    "id": 1004,
    "user": {"login": "carol"},
    "created_at": "2026-04-23T13:00:00Z",
    "body": "Fourth.",
    "reactions": {}
  },
  {
    "id": 1005,
    "user": {"login": "dave"},
    "created_at": "2026-04-24T14:00:00Z",
    "body": "Fifth and final.",
    "reactions": {}
  }
]
EOF

# Mock gh: respond to `api repos/.../comments...` by dumping the
# fixture. Anything else exits non-zero so we catch unexpected calls.
cat > "$WORK/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "api" ] && [[ "\$2" == repos/*/issues/*/comments* ]]; then
  cat "$WORK/fixture.json"
  exit 0
fi
echo "mock gh: unexpected call: \$*" >&2
exit 99
EOF
chmod 0755 "$WORK/gh"

# Point the wrapper at the mock via COO_GH_REAL.
export COO_GH_REAL="$WORK/gh"

PASS=0
FAIL=0
declare -a FAILURES=()

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS+1))
    printf '  PASS  %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$name")
    printf '  FAIL  %s\n' "$name"
    printf '         expected to contain: %s\n' "$needle"
    printf '         got:\n'
    printf '%s\n' "$haystack" | sed 's/^/           /'
  fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    FAIL=$((FAIL+1))
    FAILURES+=("$name")
    printf '  FAIL  %s\n' "$name"
    printf '         expected NOT to contain: %s\n' "$needle"
    printf '         got:\n'
    printf '%s\n' "$haystack" | sed 's/^/           /'
  else
    PASS=$((PASS+1))
    printf '  PASS  %s\n' "$name"
  fi
}

assert_le() {
  local name="$1" actual="$2" max="$3"
  if [ "$actual" -le "$max" ]; then
    PASS=$((PASS+1))
    printf '  PASS  %s (%d <= %d)\n' "$name" "$actual" "$max"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$name")
    printf '  FAIL  %s (%d > %d)\n' "$name" "$actual" "$max"
  fi
}

# ---- TEST 1: default projection contains all 5 comments ----
out="$("$WRAPPER" foo/bar 1)"
assert_contains "default projection: comment 1 header" "$out" "## comment 1 (alice, 2026-04-20)"
assert_contains "default projection: comment 5 header" "$out" "## comment 5 (dave, 2026-04-24)"
assert_contains "default projection: footer present" "$out" "5 of 5 comments shown"

# ---- TEST 2: reactions sum is rendered ----
assert_contains "reactions: alice +3 (2 thumbs + 1 heart)" "$out" "[+3 reactions]"
assert_contains "reactions: laugh counts" "$out" "[+3 reactions]"

# ---- TEST 3: multi-line body collapses to ' / ' ----
assert_contains "multi-line collapses" "$out" "Multi / line / body / should / collapse"

# ---- TEST 4: long body gets truncated with ... suffix ----
assert_contains "long body has ellipsis" "$out" "..."
assert_not_contains "long body does NOT contain final phrase" "$out" "comfortable margin"

# ---- TEST 5: byte-ceiling default keeps result well under 10 KB ----
n="$(printf '%s' "$out" | wc -c)"
assert_le "default output under 10 KB" "$n" 10240

# ---- TEST 6: --full returns the raw JSON unmodified ----
out_full="$("$WRAPPER" foo/bar 1 --full)"
assert_contains "--full has raw JSON marker" "$out_full" '"id": 1001'
assert_contains "--full has full long body" "$out_full" "comfortable margin"
assert_not_contains "--full has no projection footer" "$out_full" "comments shown"

# ---- TEST 7: --limit 2 returns the most recent 2 comments ----
out_limit="$("$WRAPPER" foo/bar 1 --limit 2)"
assert_contains "--limit: includes comment 4" "$out_limit" "carol, 2026-04-23"
assert_contains "--limit: includes comment 5" "$out_limit" "dave, 2026-04-24"
assert_not_contains "--limit: excludes comment 1" "$out_limit" "alice, 2026-04-20"
assert_contains "--limit: footer reports limit" "$out_limit" "limited to 2 of 5"

# ---- TEST 8: --max-bytes truncates and reports ----
out_small="$("$WRAPPER" foo/bar 1 --max-bytes 200)"
assert_contains "--max-bytes: truncated footer" "$out_small" "truncated to"
assert_contains "--max-bytes: footer says 'pass --full'" "$out_small" "pass --full to retrieve all"

# ---- TEST 9: --body-chars overrides projection length ----
out_long="$("$WRAPPER" foo/bar 1 --body-chars 200)"
assert_contains "--body-chars 200: long body present" "$out_long" "comfortable margin"

# ---- TEST 10: bad arg (non-numeric issue) exits 2 ----
ec=0
"$WRAPPER" foo/bar abc >/dev/null 2>&1 || ec=$?
if [ "$ec" = "2" ]; then
  PASS=$((PASS+1))
  printf '  PASS  bad issue number: exit 2\n'
else
  FAIL=$((FAIL+1))
  FAILURES+=("bad issue number exit code")
  printf '  FAIL  bad issue number: exit %s, expected 2\n' "$ec"
fi

# ---- TEST 11: missing repo exits 2 ----
ec=0
"$WRAPPER" 1 >/dev/null 2>&1 || ec=$?
if [ "$ec" = "2" ]; then
  PASS=$((PASS+1))
  printf '  PASS  missing args: exit 2\n'
else
  FAIL=$((FAIL+1))
  FAILURES+=("missing args exit code")
  printf '  FAIL  missing args: exit %s, expected 2\n' "$ec"
fi

printf '\n'
printf 'Total: %d pass, %d fail\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed tests:\n'
  for f in "${FAILURES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
exit 0
