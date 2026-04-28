#!/usr/bin/env bash
# Smoke test for scripts/filter-webhook-self-echo.sh.
#
# Covers the five contract cases:
#   1. self-echo prompt → blocked (decision: block)
#   2. mixed prompt (webhook block + untagged user content) → pass-through
#   3. foreign-session prompt (webhook block, different session_id) → pass-through
#   4. multi-block prompt (one self + one foreign) → pass-through
#   5. opt-out env (VADE_NO_SELF_ECHO_FILTER=1) → pass-through even on self-echo
#   6. malformed input (empty, non-JSON) → pass-through silently
#
# Exits 0 on full pass; 1 on any failure (with FAIL line on stderr).
#
# vade-app/vade-runtime#136.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/filter-webhook-self-echo.sh"

if [ ! -x "$HOOK" ] && [ ! -f "$HOOK" ]; then
  echo "FAIL: hook missing at $HOOK" >&2
  exit 1
fi

SID="cse_TESTSID0000000000000000000000"
SID_NO_CSE="${SID#cse_}"
URL="https://claude.ai/code/session_${SID_NO_CSE}"
FOREIGN_URL="https://claude.ai/code/session_DIFFERENTID000000000000000000"

# Helper: build the hook input JSON.
mk_input() {
  local prompt="$1" sid="${2:-$SID}"
  jq -n --arg sid "$sid" --arg p "$prompt" '{
    session_id: $sid,
    transcript_path: "/tmp/x.jsonl",
    cwd: "/tmp",
    permission_mode: "default",
    hook_event_name: "UserPromptSubmit",
    prompt: $p
  }'
}

# Helper: run the hook, return stdout.
run_hook() {
  printf '%s' "$1" | bash "$HOOK" 2>/dev/null || true
}

PASSED=0

assert_block() {
  local name="$1" out="$2"
  if ! printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    echo "FAIL: [$name] expected decision=block, got: $out" >&2
    exit 1
  fi
  PASSED=$((PASSED + 1))
  echo "  - [$name] blocked OK"
}

assert_passthrough() {
  local name="$1" out="$2"
  if [ -n "${out//[[:space:]]/}" ]; then
    echo "FAIL: [$name] expected empty output (pass-through), got: $out" >&2
    exit 1
  fi
  PASSED=$((PASSED + 1))
  echo "  - [$name] pass-through OK"
}

# Test 1: pure self-echo → block.
self_block="<github-webhook-activity>
Author: vade-coo
Comment: \"hello\n${URL}\"
</github-webhook-activity>"
out="$(run_hook "$(mk_input "$self_block")")"
assert_block "self-echo" "$out"

# Test 2: mixed prompt with untagged content → pass-through.
mixed="Hello, please look at this: $self_block"
out="$(run_hook "$(mk_input "$mixed")")"
assert_passthrough "mixed-untagged" "$out"

# Test 3: foreign-session webhook block → pass-through.
foreign="<github-webhook-activity>
Author: vade-coo
Comment: \"sibling event\n${FOREIGN_URL}\"
</github-webhook-activity>"
out="$(run_hook "$(mk_input "$foreign")")"
assert_passthrough "foreign-session" "$out"

# Test 4: multi-block (one self + one foreign) → pass-through (any-foreign blocks the block decision).
multi="$self_block

$foreign"
out="$(run_hook "$(mk_input "$multi")")"
assert_passthrough "multi-block-mixed" "$out"

# Test 5: opt-out env disables filter.
out="$(VADE_NO_SELF_ECHO_FILTER=1 printf '%s' "$(mk_input "$self_block")" | VADE_NO_SELF_ECHO_FILTER=1 bash "$HOOK" 2>/dev/null || true)"
assert_passthrough "opt-out-env" "$out"

# Test 6: malformed input → pass-through silently.
out="$(printf '%s' "" | bash "$HOOK" 2>/dev/null || true)"
assert_passthrough "empty-input" "$out"
out="$(printf '%s' "not json at all" | bash "$HOOK" 2>/dev/null || true)"
assert_passthrough "non-json-input" "$out"

# Test 7: webhook-block prompt missing session_id field → pass-through (fail-open).
no_sid_input="$(jq -n --arg p "$self_block" '{prompt: $p, hook_event_name: "UserPromptSubmit"}')"
out="$(printf '%s' "$no_sid_input" | bash "$HOOK" 2>/dev/null || true)"
assert_passthrough "missing-session_id" "$out"

# Test 8: bare session_id (no cse_ prefix) — strip-prefix logic must still match.
bare_sid="BARESID0000000000000000000000"
bare_url="https://claude.ai/code/session_${bare_sid}"
bare_block="<github-webhook-activity>
Author: vade-coo
Comment: \"bare-id case\n${bare_url}\"
</github-webhook-activity>"
out="$(run_hook "$(mk_input "$bare_block" "$bare_sid")")"
assert_block "bare-session-id" "$out"

echo "OK: filter-webhook-self-echo smoke — $PASSED tests passed"
