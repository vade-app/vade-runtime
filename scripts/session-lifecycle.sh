#!/usr/bin/env bash
# Print a session-lifecycle reminder for Claude Code agents working in
# any vade-app repo. Two modes:
#
#   session-lifecycle.sh         → boot reminder (SessionStart hook)
#   session-lifecycle.sh --end   → end-of-session reminder (Stop hook)
#
# Reminder-only. The script does not call Mem0, does not read Mem0,
# does not commit files. Its output tells Claude what to do; Claude
# does the work via MCP tools.
#
# See vade-coo-memory/coo/mem0_sop.md for the full SOP.
# See docs/briefings/003-claude-code-cross-session-state.md in
# vade-core for the design rationale.
#
# Graceful no-op if sourced libraries or node are missing; never
# breaks session start or stop.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

MODE="start"
if [ "${1:-}" = "--end" ]; then
  MODE="end"
fi

# Claude Code's Write tool resolves ~/ to /home/user in the cloud
# container while bash $HOME is /root. Plans authored through
# Claude's tools therefore land at a different path than the hook
# would see. Search both so the candidate list is complete
# regardless of which home a writer used.
PLANS_DIR="$HOME/.claude/plans"
CLAUDE_PLANS_DIR="/home/user/.claude/plans"

STATE_DIR="$HOME/.vade/agent-state"
RUN_ID_FILE="$STATE_DIR/current-run-id"
mkdir -p "$STATE_DIR" 2>/dev/null || true

list_plans() {
  {
    [ -d "$PLANS_DIR" ]        && find "$PLANS_DIR"        -maxdepth 1 -type f -name '*.md' 2>/dev/null
    [ "$PLANS_DIR" != "$CLAUDE_PLANS_DIR" ] && [ -d "$CLAUDE_PLANS_DIR" ] \
                               && find "$CLAUDE_PLANS_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null
  } | sort -u
}

if [ "$MODE" = "start" ]; then
  RUN_ID="run-$(date -u +%Y-%m-%dT%H%M%S)"
  echo "$RUN_ID" > "$RUN_ID_FILE" 2>/dev/null || true

  echo "───────────────────────────────────────────────────────────────"
  echo "Session lifecycle (SOP-MEM-001 §5)"
  echo ""
  echo "Runtime identity: agent_id=\"claude-code\""
  echo "Suggested run_id: $RUN_ID"
  echo ""
  echo "On start:"
  echo "  • Run search_memories with filter"
  echo "    {AND: [{user_id: \"ven\"}, {agent_id: \"claude-code\"}]}"
  echo "    Pull the most recent episodic entries. Check artifact_refs"
  echo "    for any in-flight plan files from prior sessions."
  echo ""

  plans="$(list_plans || true)"
  if [ -n "$plans" ]; then
    echo "  • Plan files already present:"
    while IFS= read -r p; do
      [ -n "$p" ] && echo "      - $p"
    done <<< "$plans"
    echo "    These may be stale from a prior session or pre-committed"
    echo "    work. Cross-reference with the Mem0 hand-off above."
    echo ""
  fi

  echo "Full SOP: vade-coo-memory/coo/mem0_sop.md"
  echo "───────────────────────────────────────────────────────────────"
  exit 0
fi

# --- end mode ---

RUN_ID=""
if [ -f "$RUN_ID_FILE" ] && [ -s "$RUN_ID_FILE" ]; then
  RUN_ID="$(cat "$RUN_ID_FILE")"
fi

echo "───────────────────────────────────────────────────────────────"
echo "Session lifecycle — end of session (SOP-MEM-001 §5)"
echo ""
if [ -n "$RUN_ID" ]; then
  echo "run_id: $RUN_ID"
  echo ""
fi
echo "Before the container tears down:"
echo ""
echo "  1. Commit any plan files worth preserving."
echo "     Path convention: <working-repo>/.vade/plans/<slug>.md"
echo "     Commit via git CLI if GITHUB_TOKEN is set, else via"
echo "     GitHub MCP (create_or_update_file)."

plans="$(list_plans || true)"
if [ -n "$plans" ]; then
  echo ""
  echo "     Candidate files:"
  while IFS= read -r p; do
    [ -n "$p" ] && echo "       - $p"
  done <<< "$plans"
fi

echo ""
echo "  2. Write ONE episodic Mem0 entry with full scope:"
echo "       user_id    = \"ven\""
echo "       agent_id   = \"claude-code\""
if [ -n "$RUN_ID" ]; then
  echo "       run_id     = \"$RUN_ID\""
else
  echo "       run_id     = (current session run_id)"
fi
echo "       metadata   = { memory_type: \"episodic\","
echo "                      event: \"session_summary\","
echo "                      artifact_refs: [\"<repo>/.vade/plans/<slug>.md@<sha>\"],"
echo "                      retention: \"ephemeral\","
echo "                      expiration_date: <now + 30 days> }"
echo ""
echo "  3. If this session was the COO working in vade-coo-memory,"
echo "     also write a session log to vade-agent-logs per that"
echo "     repo's CLAUDE.md template."
echo ""
echo "Full SOP: vade-coo-memory/coo/mem0_sop.md"
echo "───────────────────────────────────────────────────────────────"
