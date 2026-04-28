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
# See vade-coo-memory/coo/briefings/003-claude-code-cross-session-state.md
# for the design rationale (relocated from vade-core/docs/briefings/
# per MEMO-2026-04-27-02).
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

boot_log_record "session-lifecycle-$MODE" start
trap '_rc=$?; boot_log_record "session-lifecycle-'"$MODE"'" end $([ $_rc -eq 0 ] && echo ok || echo fail) rc=$_rc' EXIT

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
  echo "On start (SOP-MEM-001 v1.1 §5):"
  echo "  • Identity load — get_memories with filter"
  echo "      {AND: [{user_id: \"coo\"}]}"
  echo "    Pulls every core_belief (CB-*) and overarching_goal (OG-*)."
  echo "  • Recent-episodic handoff — search_memories with filter"
  echo "      {AND: [{user_id: \"ven\"},"
  echo "             {metadata: {created_by: \"coo\"}},"
  echo "             {created_at: {gte: \"<now - 24h>\"}}]}"
  echo "    Pulls the prior session's session_summary and any other"
  echo "    recent episodic entries. Check artifact_refs for in-flight"
  echo "    plan files from prior sessions."
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

  # Prior idle-close stub logs: if the watchdog
  # (vade-app/vade-agent-logs#67) fired a mechanical close on a recent
  # session, the next interactive COO owes a real summary. Surface
  # any unpaired stubs from the last 3 days so the agent doesn't have
  # to discover them.
  agent_logs_dir=""
  for _cand in "$HOME/GitHub/vade-app/vade-agent-logs" "/home/user/vade-agent-logs"; do
    if [ -d "$_cand" ]; then agent_logs_dir="$_cand"; break; fi
  done
  if [ -n "$agent_logs_dir" ] && [ -d "$agent_logs_dir/sessions" ]; then
    pending_stubs="$(find "$agent_logs_dir/sessions" -type f \
      -name 'coo-idle-close-*.md' -mtime -3 2>/dev/null | sort)"
    if [ -n "$pending_stubs" ]; then
      while IFS= read -r stub; do
        [ -z "$stub" ] && continue
        sid="$(basename "$stub" .md)"
        sid="${sid#coo-idle-close-}"
        # Skip stubs that already have a paired summary file in the same dir.
        stub_dir="$(dirname "$stub")"
        if [ -f "$stub_dir/coo-summary-on-${sid}.md" ]; then continue; fi
        if [ -z "${idle_close_header_printed:-}" ]; then
          echo "  • Prior session(s) ended on idle (vade-app/vade-agent-logs#67):"
          idle_close_header_printed=1
        fi
        echo "      - ${stub#"$agent_logs_dir/"}"
      done <<< "$pending_stubs"
      if [ -n "${idle_close_header_printed:-}" ]; then
        echo "    These owe a real session summary. Append a sibling"
        echo "    coo-summary-on-<sessionId>.md in the same dir, or amend"
        echo "    the stub in place with what was worked on."
        echo ""
      fi
    fi
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

# Stop-hook context-injection contract: Claude Code only surfaces a
# Stop hook's reminder text to the next turn when the hook returns
# {"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"..."}}.
# Plain stdout from a Stop hook lands in transcript-mode logs (Ctrl-R)
# and is invisible to Claude — which is why this reminder silently
# stopped reaching agents at some point in the harness lifetime,
# despite the hook firing cleanly. Capture all reminder text into a
# buffer, then emit it wrapped in the JSON envelope below.
END_BUF="$(mktemp -t vade-session-end.XXXXXX 2>/dev/null || mktemp)"
{
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
echo "  2. Write ONE episodic Mem0 entry (SOP-MEM-001 v1.1 §5):"
echo "       user_id    = \"ven\""
echo "       agent_id   = \"claude-code\"   # forward-compat; not indexed"
echo "       # Do NOT pass run_id as a top-level arg — it creates a"
echo "       # per-session RUN entity and shards cross-session recall."
echo "       # The run_id belongs in metadata.source_session."
if [ -n "$RUN_ID" ]; then
  RUN_ID_FIELD="\"$RUN_ID\""
else
  RUN_ID_FIELD="\"<current session run_id>\""
fi
echo "       metadata   = { memory_type:     \"episodic\","
echo "                      event:           \"session_summary\","
echo "                      created_by:      \"coo\","
echo "                      source_session:  $RUN_ID_FIELD,"
echo "                      artifact_refs:   [\"<repo>/.vade/plans/<slug>.md@<sha>\"],"
echo "                      retention:       \"ephemeral\","
echo "                      expiration_date: <now + 30 days> }"
echo ""
echo "  3. Consider a Journal entry. Pause and ask: did anything happen"
echo "     this session that's worth a Journal post — a pattern noticed,"
echo "     a meta-observation about the COO or the COO ↔ Ven dynamic,"
echo "     a thought that doesn't yet fit memo / essay / RFC? If yes,"
echo "     scan existing Journal threads for a topic match: comment to"
echo "     extend, or open a new thread for a separate direction. The"
echo "     bar is low (one paragraph is fine), but the floor is honest"
echo "     reflection — if nothing comes to mind in ~30 seconds, skip."
echo "     Skipping is a normal outcome; forcing a post defeats the"
echo "     purpose."
echo "     Norms:    vade-coo-memory/coo/agent-boot-discussions-check.md §Journal"
echo "     Category: https://github.com/vade-app/vade-core/discussions/categories/journal"
echo ""
echo "  4. If this session was the COO working in vade-coo-memory,"
echo "     also write a session log to vade-agent-logs per that"
echo "     repo's CLAUDE.md template."
echo ""

# Step 5 (conditional): the transcript-export Stop hook fires before
# this script (settings.json hooks.Stop array order), so by now any
# meta.json or export-error.txt sidecar is already on disk. Surface
# the file paths so the agent commits them as part of step 4. Skip
# the step entirely when nothing was dropped (hook missing, deps
# missing, dry-run, etc.) — silence is the better signal than a stale
# instruction.
agent_logs_dir=""
for _cand in "$HOME/GitHub/vade-app/vade-agent-logs" "/home/user/vade-agent-logs"; do
  if [ -d "$_cand" ]; then agent_logs_dir="$_cand"; break; fi
done
if [ -n "$agent_logs_dir" ] && [ -d "$agent_logs_dir/transcripts" ]; then
  recent_drops="$(find "$agent_logs_dir/transcripts" -type f \
    \( -name '*.meta.json' -o -name '*.export-error.txt' \) \
    -mmin -60 2>/dev/null | sort)"
  if [ -n "$recent_drops" ]; then
    echo "  5. The transcript-export Stop hook fired this session"
    echo "     (vade-app/vade-agent-logs#64 Batch 2). Files in"
    echo "     vade-agent-logs to commit alongside your session log:"
    while IFS= read -r _f; do
      [ -n "$_f" ] && echo "       - ${_f#"$agent_logs_dir/"}"
    done <<< "$recent_drops"
    echo ""
    echo "     The redacted+encrypted ciphertext is already in R2 — the"
    echo "     .meta.json sidecar carries the bucket+key. Sidecars are"
    echo "     append-only; commit verbatim. If a .export-error.txt is"
    echo "     present instead of (or alongside) a .meta.json, surface"
    echo "     the failure in your session log so future COOs can see it."
    echo ""
  fi
fi

echo "Full SOP: vade-coo-memory/coo/mem0_sop.md"
echo "───────────────────────────────────────────────────────────────"
} > "$END_BUF"

# Emit captured reminder as Stop-hook structured output so Claude
# actually sees it on the next turn. Falls back to plain stdout if
# node is missing — strictly worse than the JSON path (Claude won't
# see it), but the script must remain a graceful no-op when deps are
# missing rather than aborting the Stop chain.
if check_cmd node; then
  node -e '
    const fs = require("fs");
    const text = fs.readFileSync(process.argv[1], "utf8");
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "Stop",
        additionalContext: text
      }
    }) + "\n");
  ' "$END_BUF"
else
  cat "$END_BUF"
fi
rm -f "$END_BUF"
