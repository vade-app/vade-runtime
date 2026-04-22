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
WORKSPACE_IDENTITY_LINK="/home/user/CLAUDE.md"
WORKSPACE_MCP_LINK="/home/user/.mcp.json"
WORKSPACE_MCP_SRC="/home/user/vade-runtime/.mcp.json"
SETUP_RECEIPT="/home/user/.vade-cloud-state/setup-receipt.json"

if [ ! -f "$CLAUDE_MD" ]; then
  echo "[vade-setup] coo-identity-digest: $CLAUDE_MD not found; skipping."
  exit 0
fi

# Check whether Claude Code's built-in memory loader already picked up
# the identity file via /home/user/CLAUDE.md → vade-coo-memory/CLAUDE.md.
# When the symlink is present, the file is in context from turn one
# and re-echoing would just duplicate content. When it's missing,
# echo as a fallback so identity still lands (same behavior as before
# C6a).
identity_link_live=false
if [ -L "$WORKSPACE_IDENTITY_LINK" ] && \
   [ "$(readlink -f "$WORKSPACE_IDENTITY_LINK" 2>/dev/null)" = "$(readlink -f "$CLAUDE_MD" 2>/dev/null)" ]; then
  identity_link_live=true
fi

if [ "$identity_link_live" = "true" ]; then
  echo "───────────────────────────────────────────────────────────────"
  echo "COO identity: /home/user/CLAUDE.md → vade-coo-memory/CLAUDE.md"
  echo "(loaded by harness memory; skipping echo to avoid duplicate context)"
  echo "───────────────────────────────────────────────────────────────"
else
  echo "───────────────────────────────────────────────────────────────"
  echo "COO identity boot (vade-coo-memory/CLAUDE.md)"
  echo "───────────────────────────────────────────────────────────────"
  cat "$CLAUDE_MD"
fi

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

# MCP surface probe — prerequisites that Claude Code needed at process
# start for project-scope MCP servers (agentmail, github-coo, mem0) to
# register. We can't see the live tool list from a Bash hook, but if
# any prerequisite is missing the tools cannot have been loaded.
# Surface these loudly so the agent knows to avoid attributable writes
# until a /resume picks up the fix we've just applied.
echo ""
echo "───────────────────────────────────────────────────────────────"
echo "MCP surface probe"
echo "───────────────────────────────────────────────────────────────"

mcp_link_ok=false
mcp_link_state="missing"
if [ -L "$WORKSPACE_MCP_LINK" ]; then
  if [ "$(readlink -f "$WORKSPACE_MCP_LINK" 2>/dev/null)" = "$(readlink -f "$WORKSPACE_MCP_SRC" 2>/dev/null)" ]; then
    mcp_link_ok=true
    mcp_link_state="ok (→ $(readlink "$WORKSPACE_MCP_LINK" 2>/dev/null))"
  else
    mcp_link_state="wrong target (→ $(readlink "$WORKSPACE_MCP_LINK" 2>/dev/null))"
  fi
elif [ -e "$WORKSPACE_MCP_LINK" ]; then
  mcp_link_state="present but not a symlink"
fi
echo "  /home/user/.mcp.json:     $mcp_link_state"

id_link_state="missing"
if [ -L "$WORKSPACE_IDENTITY_LINK" ]; then
  if [ "$identity_link_live" = "true" ]; then
    id_link_state="ok (→ $(readlink "$WORKSPACE_IDENTITY_LINK" 2>/dev/null))"
  else
    id_link_state="wrong target (→ $(readlink "$WORKSPACE_IDENTITY_LINK" 2>/dev/null))"
  fi
elif [ -e "$WORKSPACE_IDENTITY_LINK" ]; then
  id_link_state="present but not a symlink"
fi
echo "  /home/user/CLAUDE.md:     $id_link_state"

# Any failure = session started without the workspace-scope overrides.
# Surface the fix path instead of letting the agent guess.
if [ "$mcp_link_ok" != "true" ] || [ "$identity_link_live" != "true" ]; then
  echo ""
  echo "  ⚠ Workspace-scope overrides were NOT in place at Claude Code startup."
  echo "    Project-scope MCPs (agentmail, github-coo, mem0) did not load this session,"
  echo "    and COO identity was not auto-loaded by the harness memory system."
  echo "    session-start-sync.sh has re-applied the symlinks in this hook pass."
  echo "    Resume the session (/resume) to pick up the full MCP + identity surface."
fi

echo "───────────────────────────────────────────────────────────────"

# Cloud build-time receipt — what did cloud-setup.sh actually do at
# snapshot build? Present = build ran; missing = build skipped or the
# setup script field in the Anthropic cloud UI is not wired.
echo ""
echo "───────────────────────────────────────────────────────────────"
echo "Cloud build-time receipt"
echo "───────────────────────────────────────────────────────────────"
if [ -f "$SETUP_RECEIPT" ]; then
  if check_cmd node; then
    node -e '
      const fs = require("fs");
      try {
        const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        for (const k of Object.keys(r)) {
          const v = r[k];
          console.log("  " + (k + ":").padEnd(25) + " " + v);
        }
      } catch (e) { console.log("  (unreadable: " + e.message + ")"); }
    ' "$SETUP_RECEIPT" 2>/dev/null || cat "$SETUP_RECEIPT"
  else
    cat "$SETUP_RECEIPT"
  fi
else
  echo "  (no receipt at $SETUP_RECEIPT)"
  echo "  cloud-setup.sh did not run at snapshot build, or ran but aborted before writing the receipt."
  echo "  Check the Anthropic cloud env 'Setup script' field —"
  echo "    expected: bash /home/user/vade-runtime/scripts/cloud-setup.sh"
fi
echo "───────────────────────────────────────────────────────────────"
