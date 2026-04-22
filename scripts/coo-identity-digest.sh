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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

MEM_REPO="${COO_MEMORY_DIR:-/home/user/vade-coo-memory}"
CLAUDE_MD="$MEM_REPO/CLAUDE.md"
MEMOS="$MEM_REPO/coo/memos.md"
BOOTSTRAP_LOG="${HOME}/.vade/coo-bootstrap.log"
SETTINGS_FILE="${HOME}/.claude/settings.json"

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

# Bootstrap posture — loud surface of whether this session boots with
# a full identity. Three signals:
#   (a) last coo-bootstrap outcome (from the log)
#   (b) env vars actually present in this hook's process
#   (c) env vars present in ~/.claude/settings.json (what MCP servers got)
# When (b) diverges from (c), the current session's MCP tools are
# stale — a restart will pick up the populated env block.
#
# SessionStart hooks run in parallel. Without the wait below, we'd
# sample env and settings.json mid-bootstrap and falsely report
# degraded even when coo-bootstrap eventually completes cleanly (the
# first user-visible regression after PR #20 landed: verification
# run reported "degraded" despite OK-step=complete in the log).
#
# Strategy: poll the bootstrap log for a terminal state (OK/FAIL/SKIP)
# timestamped at-or-after this digest's start. If bootstrap hasn't
# written for this session yet, wait — but only as long as a
# coo-bootstrap.sh process is actually running, plus a short grace
# window. A hook that never fires (or a standalone digest invocation)
# exits the wait quickly instead of wedging boot for the full timeout.
_digest_start_epoch="$(date -u +%s)"
_digest_wait_timeout=60
_digest_wait_elapsed=0
_digest_saw_fresh=0
while [ "$_digest_wait_elapsed" -lt "$_digest_wait_timeout" ]; do
  if [ -f "$BOOTSTRAP_LOG" ]; then
    _last_line="$(tail -n 1 "$BOOTSTRAP_LOG" 2>/dev/null || true)"
    _last_ts="${_last_line%% *}"
    _last_state="$(printf '%s' "$_last_line" | awk '{print $2}')"
    case "$_last_state" in
      OK|FAIL|SKIP)
        _last_epoch="$(date -u -d "$_last_ts" +%s 2>/dev/null || echo 0)"
        if [ "$_last_epoch" -ge "$_digest_start_epoch" ]; then
          _digest_saw_fresh=1
          break
        fi
        ;;
    esac
  fi
  # Fast-exit when bootstrap isn't running and we've given it a 2s
  # grace to start. Covers three cases: hook disabled, bootstrap
  # already finished before digest started, standalone debug invocation.
  if [ "$_digest_wait_elapsed" -ge 2 ] && ! pgrep -f coo-bootstrap.sh >/dev/null 2>&1; then
    break
  fi
  sleep 1
  _digest_wait_elapsed=$((_digest_wait_elapsed + 1))
done

echo ""
echo "───────────────────────────────────────────────────────────────"
echo "Bootstrap posture"
echo "───────────────────────────────────────────────────────────────"

if [ -f "$BOOTSTRAP_LOG" ]; then
  last_line="$(tail -n 1 "$BOOTSTRAP_LOG" 2>/dev/null || true)"
  [ -n "$last_line" ] && echo "  Last bootstrap: $last_line"
else
  echo "  Last bootstrap: (no log at $BOOTSTRAP_LOG)"
fi

if [ "$_digest_saw_fresh" -eq 0 ]; then
  if [ "$_digest_wait_elapsed" -ge "$_digest_wait_timeout" ]; then
    echo "  WARN: timed out after ${_digest_wait_timeout}s waiting for a fresh bootstrap terminal state."
  else
    echo "  Note: no fresh bootstrap state this session (hook didn't fire, or finished before digest started)."
  fi
fi

# Re-source coo-env in case bootstrap just wrote it. common.sh sourced
# the file once at script load; a second source picks up any keys
# added during the wait above.
# shellcheck source=/dev/null
[ -f "${HOME}/.vade/coo-env" ] && . "${HOME}/.vade/coo-env"

env_has_pat="no"; env_has_mail="no"
[ -n "${GITHUB_MCP_PAT:-}" ]    && env_has_pat="yes"
[ -n "${AGENTMAIL_API_KEY:-}" ] && env_has_mail="yes"

settings_pat="unknown"; settings_mail="unknown"
if [ -f "$SETTINGS_FILE" ] && check_cmd node; then
  probe="$(node -e '
    const fs = require("fs");
    try {
      const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const e = cfg.env || {};
      console.log((e.GITHUB_MCP_PAT ? "yes" : "no") + " " + (e.AGENTMAIL_API_KEY ? "yes" : "no"));
    } catch (_) { console.log("unknown unknown"); }
  ' "$SETTINGS_FILE" 2>/dev/null || echo "unknown unknown")"
  settings_pat="${probe%% *}"
  settings_mail="${probe##* }"
fi

echo "  Process env:       GITHUB_MCP_PAT=$env_has_pat  AGENTMAIL_API_KEY=$env_has_mail"
echo "  settings.json env: GITHUB_MCP_PAT=$settings_pat  AGENTMAIL_API_KEY=$settings_mail"

if [ "$env_has_pat" = "yes" ] && [ "$env_has_mail" = "yes" ]; then
  echo "  Full identity loaded; MCP tools (github, agentmail) should have env."
elif [ "$settings_pat" = "yes" ] && [ "$settings_mail" = "yes" ]; then
  echo ""
  echo "  WARN: env populated in settings.json but not in this process."
  echo "  MCP servers were spawned before the env block was written."
  echo "  Next session in this container will boot fully loaded."
else
  echo ""
  echo "  WARN: identity is degraded — required env vars are missing."
  echo "  Inspect $BOOTSTRAP_LOG for the failing step, then re-run:"
  echo "    VADE_FORCE_COO_BOOTSTRAP=1 bash /home/user/vade-runtime/scripts/coo-bootstrap.sh"
fi

echo "───────────────────────────────────────────────────────────────"
