#!/usr/bin/env bash
# test-gh-coo-wrap: smoke-test the gh wrapper that auto-injects the
# Claude Code session URL onto --body for covered `gh` subcommands.
#
# Strategy: install a mock `gh-real` that prints its JSON-encoded
# argv (and stdin) to stdout, then run the wrapper with various arg
# shapes and assert the augmented body appears (or doesn't, for
# pass-through cases) where expected.
#
# Run: bash scripts/test-gh-coo-wrap.sh
# Exit: 0 if all assertions pass, non-zero otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/gh-coo-wrap.sh"

[ -x "$WRAPPER" ] || { echo "FAIL: wrapper not executable at $WRAPPER"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Mock gh-real: dump its argv, one per line, to stdout. For
# --body-file we also dump the file contents marked with FILE-CONTENT:.
cat > "$WORK/gh-real" <<'EOF'
#!/usr/bin/env bash
i=0
for a in "$@"; do
  i=$((i+1))
  printf 'ARG[%d]=%s\n' "$i" "$a"
done
# If a body-file path was given, dump its contents too.
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ]; then
    if [ -f "$a" ]; then
      printf 'FILE-CONTENT-START\n'
      cat "$a"
      printf '\nFILE-CONTENT-END\n'
    fi
  fi
  case "$a" in
    --body-file=*)
      bf="${a#--body-file=}"
      if [ -f "$bf" ]; then
        printf 'FILE-CONTENT-START\n'
        cat "$bf"
        printf '\nFILE-CONTENT-END\n'
      fi
      ;;
  esac
  prev="$a"
done
EOF
chmod 0755 "$WORK/gh-real"

# Synthetic session env for tests.
export CLAUDE_CODE_REMOTE_SESSION_ID="cse_TESTID123"
export COO_GH_REAL="$WORK/gh-real"
EXPECTED_URL="https://claude.ai/code/session_TESTID123"

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

# ---- TEST 1: gh pr create --body "X" augments body ----
out="$("$WRAPPER" pr create --title t --body "hello world")"
assert_contains "pr create --body augments" "$out" "$EXPECTED_URL"
assert_contains "pr create --body preserves original" "$out" "hello world"

# ---- TEST 2: gh pr comment --body "X" augments ----
out="$("$WRAPPER" pr comment 123 --body "ack")"
assert_contains "pr comment --body augments" "$out" "$EXPECTED_URL"

# ---- TEST 3: gh issue create --body "X" augments ----
out="$("$WRAPPER" issue create --title t --body "report")"
assert_contains "issue create --body augments" "$out" "$EXPECTED_URL"

# ---- TEST 4: gh issue comment --body "X" augments ----
out="$("$WRAPPER" issue comment 1 --body "thanks")"
assert_contains "issue comment --body augments" "$out" "$EXPECTED_URL"

# ---- TEST 5: gh pr review --body "X" augments ----
out="$("$WRAPPER" pr review 9 --request-changes --body "needs fix")"
assert_contains "pr review --body augments" "$out" "$EXPECTED_URL"

# ---- TEST 6: --body= form (single token) augments ----
out="$("$WRAPPER" pr create --title t --body="long body text")"
assert_contains "--body= form augments" "$out" "$EXPECTED_URL"

# ---- TEST 7: -b short form augments ----
out="$("$WRAPPER" pr create --title t -b "short")"
assert_contains "-b short form augments" "$out" "$EXPECTED_URL"

# ---- TEST 8: idempotent (body already has URL) ----
existing_url="https://claude.ai/code/session_OLDID"
out="$("$WRAPPER" pr create --title t --body "preexisting $existing_url")"
assert_contains "idempotent: preexisting URL preserved" "$out" "$existing_url"
assert_not_contains "idempotent: new URL not appended" "$out" "$EXPECTED_URL"

# ---- TEST 9: empty body — no augmentation ----
out="$("$WRAPPER" pr create --title t --body "")"
assert_not_contains "empty body: not augmented" "$out" "$EXPECTED_URL"

# ---- TEST 10: pass-through — pr review --approve (no body) ----
out="$("$WRAPPER" pr review 9 --approve)"
assert_not_contains "pr review --approve: pass-through" "$out" "$EXPECTED_URL"

# ---- TEST 11: pass-through — non-covered subcommand (pr list) ----
out="$("$WRAPPER" pr list --state open)"
assert_not_contains "pr list: pass-through" "$out" "$EXPECTED_URL"

# ---- TEST 12: pass-through — gh api (uncovered) ----
out="$("$WRAPPER" api '/repos/foo/bar' -f body="x")"
assert_not_contains "gh api: pass-through" "$out" "$EXPECTED_URL"

# ---- TEST 13: --body-file augments (file contents written augmented) ----
echo "from a file" > "$WORK/body.txt"
out="$("$WRAPPER" pr create --title t --body-file "$WORK/body.txt")"
assert_contains "--body-file augments file content" "$out" "$EXPECTED_URL"
assert_contains "--body-file preserves original content" "$out" "from a file"

# ---- TEST 14: --body-file=- reads stdin and augments ----
out="$(printf 'from stdin' | "$WRAPPER" pr create --title t --body-file -)"
assert_contains "--body-file=stdin augments" "$out" "$EXPECTED_URL"
assert_contains "--body-file=stdin preserves" "$out" "from stdin"

# ---- TEST 15: outside-Claude (no session env) — pass-through ----
out="$(env -u CLAUDE_CODE_REMOTE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
       COO_GH_REAL="$WORK/gh-real" "$WRAPPER" pr create --title t --body "hi")"
assert_not_contains "no session env: not augmented" "$out" "claude.ai/code/session_"

# ---- TEST 16: real binary missing AND none on PATH — exit 127 ----
# Set PATH to dirs that don't contain gh so the fallback also fails.
ec=0
err="$(env -i PATH=/usr/bin:/bin HOME="$HOME" COO_GH_REAL=/nonexistent/path \
       "$WRAPPER" pr create --body "x" 2>&1 >/dev/null)" || ec=$?
if [ "$ec" = "127" ]; then
  PASS=$((PASS+1))
  printf '  PASS  missing real binary: exit 127\n'
else
  FAIL=$((FAIL+1))
  FAILURES+=("missing real binary exit code")
  printf '  FAIL  missing real binary: exit %s, expected 127\n' "$ec"
  printf '         stderr: %s\n' "$err"
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
