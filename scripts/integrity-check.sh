#!/usr/bin/env bash
# VADE cloud-session integrity check.
#
# Runs a fixed set of invariants (Groups A-E) against the current
# session and writes a structured JSON report to
# $VADE_CLOUD_STATE_DIR/integrity-check.json. Also prints a one-line
# human-readable summary to stderr so an agent invoking this directly
# sees the result without parsing JSON.
#
# Non-fatal on every path: always exits 0 even when invariants fail.
# This is a probe, not a repair tool.
#
# Invocation modes:
#   1. Automatic at boot — session-start-sync.sh calls it at end.
#   2. On-demand — `bash /home/user/vade-runtime/scripts/integrity-check.sh`
#   3. CI — tests run it after faking a SessionStart chain; Groups
#      A/B/C gate PR merges, D/E are secret-dependent and skip in CI.
#
# See the VADE integrity protocol memo (paired with this file's PR)
# for the full invariant list and rationale.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

OUT_FILE="${VADE_CLOUD_STATE_DIR}/integrity-check.json"
RUNTIME_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Array of "key|ok|detail" triples. Flat for shell; node groups by
# key prefix (A1 → A, B1 → B, etc) at write time.
RESULTS=()
_add() {
  local key="$1" ok="$2" detail="${3:-}"
  RESULTS+=("$key|$ok|$detail")
}

# ── Group A: Build-time setup ──────────────────────────────────
A1_receipt="$VADE_SETUP_RECEIPT"
if [ -f "$A1_receipt" ] && node -e 'JSON.parse(require("fs").readFileSync(process.argv[1]))' "$A1_receipt" 2>/dev/null; then
  _add A1 true "receipt at $A1_receipt parses"
else
  _add A1 false "receipt missing or unparseable at $A1_receipt"
fi

if [ -f "$VADE_BUILD_LOG" ] && grep -q 'OK cloud-setup: complete\|OK local-setup: complete' "$VADE_BUILD_LOG" 2>/dev/null; then
  _add A2 true "build.log has terminal OK line"
else
  _add A2 false "build.log missing or no terminal OK line at $VADE_BUILD_LOG"
fi

# A3: receipt asserts workspace_mcp_symlinked=true/identity_link_ok=true
# but the link is currently wrong → drift. Vice versa is also flagged.
A3_detail=""
A3_ok=true
if [ -f "$A1_receipt" ] && check_cmd node; then
  claim_mcp="$(node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1])); process.stdout.write(String(!!r.workspace_mcp_symlinked))' "$A1_receipt" 2>/dev/null || echo unknown)"
  claim_id="$(node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1])); process.stdout.write(String(!!r.identity_link_ok))' "$A1_receipt" 2>/dev/null || echo unknown)"
  observed_mcp=false
  observed_id=false
  [ -L /home/user/.mcp.json ] && observed_mcp=true
  [ -L /home/user/CLAUDE.md ] && observed_id=true
  [ "$claim_mcp" = "$observed_mcp" ] || { A3_ok=false; A3_detail="mcp_link drift: receipt=$claim_mcp observed=$observed_mcp; "; }
  [ "$claim_id" = "$observed_id" ] || { A3_ok=false; A3_detail="${A3_detail}identity_link drift: receipt=$claim_id observed=$observed_id"; }
  [ "$A3_ok" = true ] && A3_detail="receipt matches observed symlinks"
else
  A3_ok=skip
  A3_detail="receipt or node unavailable"
fi
_add A3 "$A3_ok" "$A3_detail"

# ── Group B: SessionStart hooks executable ────────────────────
SHIM_DST="$HOME/.claude/vade-hooks/dispatch.sh"
SHIM_SRC="$RUNTIME_DIR/scripts/hooks-dispatch.sh"
if [ -L "$SHIM_DST" ] && [ -f "$(readlink -f "$SHIM_DST" 2>/dev/null)" ] && [ -x "$(readlink -f "$SHIM_DST" 2>/dev/null)" ]; then
  _add B2 true "dispatch shim → $(readlink "$SHIM_DST")"
elif [ -f "$SHIM_DST" ] && [ -x "$SHIM_DST" ]; then
  _add B2 true "dispatch shim present (non-symlink) at $SHIM_DST"
else
  _add B2 false "dispatch shim missing or not executable at $SHIM_DST"
fi

# B1: re-run the resolver for each expected hook name
B1_ok=true
B1_detail=""
for name in session-start-sync coo-bootstrap coo-identity-digest discussions-digest session-lifecycle; do
  if ! [ -f "$RUNTIME_DIR/scripts/$name.sh" ]; then
    B1_ok=false
    B1_detail="${B1_detail}missing: $name.sh; "
  fi
done
[ "$B1_ok" = true ] && B1_detail="all 5 hook scripts present in runtime"
_add B1 "$B1_ok" "$B1_detail"

# B3: last SessionStart chain outcomes in claude-code.log
B3_ok=skip
B3_detail="claude-code.log not readable"
if [ -r /tmp/claude-code.log ]; then
  failures="$(grep -c 'Hook SessionStart:startup.*exit_code.*127\|No such file or directory' /tmp/claude-code.log 2>/dev/null || echo 0)"
  if [ "$failures" -gt 0 ]; then
    B3_ok=false
    B3_detail="$failures failing hook entries in claude-code.log (grep on 'No such file')"
  else
    B3_ok=true
    B3_detail="no hook failure pattern in claude-code.log"
  fi
fi
_add B3 "$B3_ok" "$B3_detail"

# B4: hooks section hash matches repo
B4_ok=skip
B4_detail="node missing"
if check_cmd node; then
  B4_ok=$(node -e '
    const fs = require("fs"); const [src, dst] = process.argv.slice(1);
    try {
      const s = JSON.parse(fs.readFileSync(src, "utf8"));
      const d = JSON.parse(fs.readFileSync(dst, "utf8"));
      const sh = JSON.stringify(s.hooks || {});
      const dh = JSON.stringify(d.hooks || {});
      process.stdout.write(sh === dh ? "true" : "false");
    } catch { process.stdout.write("skip"); }
  ' "$RUNTIME_DIR/.claude/settings.json" "$HOME/.claude/settings.json" 2>/dev/null || echo skip)
  case "$B4_ok" in
    true)  B4_detail="settings.json hooks section matches repo" ;;
    false) B4_detail="settings.json hooks drift from repo; re-run session-start-sync" ;;
    *)     B4_detail="comparison failed" ;;
  esac
fi
_add B4 "$B4_ok" "$B4_detail"

# B5: diagnostic, not pass/fail
_add B5 info "CLAUDE_PROJECT_DIR=${CLAUDE_PROJECT_DIR:-<unset>} cwd=$(pwd) HOME=$HOME"

# ── Group C: Symlinks & MCP config ────────────────────────────
if [ -L /home/user/CLAUDE.md ] && [ "$(readlink -f /home/user/CLAUDE.md)" = "$(readlink -f /home/user/vade-coo-memory/CLAUDE.md 2>/dev/null)" ]; then
  _add C1 true "/home/user/CLAUDE.md → vade-coo-memory/CLAUDE.md"
else
  _add C1 false "/home/user/CLAUDE.md symlink missing or wrong target"
fi

if [ -L /home/user/.mcp.json ] && [ "$(readlink -f /home/user/.mcp.json)" = "$(readlink -f /home/user/vade-runtime/.mcp.json 2>/dev/null)" ]; then
  _add C2 true "/home/user/.mcp.json → vade-runtime/.mcp.json"
else
  _add C2 false "/home/user/.mcp.json symlink missing or wrong target"
fi

if [ -f /home/user/.mcp.json ] && node -e 'JSON.parse(require("fs").readFileSync(process.argv[1]))' /home/user/.mcp.json 2>/dev/null; then
  _add C3 true "mcp.json parses"
else
  _add C3 false "mcp.json missing or unparseable"
fi

# ── Group D: COO identity & secrets ──────────────────────────
if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  _add D1 true "OP_SERVICE_ACCOUNT_TOKEN set (len=${#OP_SERVICE_ACCOUNT_TOKEN})"
else
  _add D1 false "OP_SERVICE_ACCOUNT_TOKEN unset in session process"
fi

if [ -f "$HOME/.vade/.coo-bootstrap-done" ]; then
  _add D2 true "marker present"
else
  _add D2 false "marker $HOME/.vade/.coo-bootstrap-done missing"
fi

if [ -f "$HOME/.vade/coo-bootstrap.log" ]; then
  tail_line="$(tail -n 1 "$HOME/.vade/coo-bootstrap.log" 2>/dev/null || true)"
  if printf '%s' "$tail_line" | grep -qE 'OK step=complete|OK step=skip-'; then
    _add D3 true "coo-bootstrap.log tail: $tail_line"
  else
    _add D3 false "coo-bootstrap.log tail non-terminal: $tail_line"
  fi
else
  _add D3 false "coo-bootstrap.log missing"
fi

if check_cmd node && [ -f "$HOME/.claude/settings.json" ]; then
  D4_missing="$(node -e '
    const fs = require("fs");
    let c = {};
    try { c = JSON.parse(fs.readFileSync(process.argv[1], "utf8")) || {}; } catch { process.exit(0); }
    const env = c.env || {};
    const req = ["GITHUB_MCP_PAT","GITHUB_TOKEN","AGENTMAIL_API_KEY"];
    process.stdout.write(req.filter(k => !env[k]).join(","));
  ' "$HOME/.claude/settings.json" 2>/dev/null)"
  if [ -z "$D4_missing" ]; then
    _add D4 true "settings.json env has GITHUB_MCP_PAT, GITHUB_TOKEN, AGENTMAIL_API_KEY"
  else
    _add D4 false "settings.json env missing: $D4_missing"
  fi
else
  _add D4 skip "node or settings.json unavailable"
fi

GIT_EMAIL="$(git config --global user.email 2>/dev/null || true)"
if [ "$GIT_EMAIL" = "coo@vade-app.dev" ]; then
  _add D5 true "gitconfig user.email=coo@vade-app.dev"
else
  _add D5 false "gitconfig user.email=$GIT_EMAIL (expected coo@vade-app.dev)"
fi

if [ -f "$HOME/.ssh/vade-coo-auth" ] && [ -f "$HOME/.ssh/vade-coo-sign" ]; then
  _add D6 true "vade-coo-auth and vade-coo-sign keys installed"
else
  _add D6 false "vade-coo-{auth,sign} keys missing in $HOME/.ssh"
fi

# ── Group E: MCP surface ─────────────────────────────────────
# Requires MCP tool calls (get_me on github and github-coo namespaces).
# An agent invoking this directly should fill E1/E2/E3/E4 into the
# JSON afterwards. CI skips E entirely.
_add E1 skip "requires-agent: call mcp__github__get_me"
_add E2 skip "requires-agent: call mcp__github-coo__get_me"
_add E3 skip "requires-agent: inspect mcp-needs-auth-cache.json"
_add E4 skip "requires-agent: observe tool namespaces"

# ── Serialize ────────────────────────────────────────────────
mkdir -p "$VADE_CLOUD_STATE_DIR" 2>/dev/null || true

if check_cmd node; then
  printf '%s\n' "${RESULTS[@]}" | node -e '
    const fs = require("fs");
    const [outFile, sessionId] = process.argv.slice(1);
    const groups = {};
    const degraded = [];
    let total = 0, okCount = 0;
    const input = fs.readFileSync(0, "utf8");
    for (const line of input.split("\n")) {
      if (!line) continue;
      const [key, ok, ...detailParts] = line.split("|");
      const detail = detailParts.join("|");
      const g = key[0];
      groups[g] = groups[g] || {};
      const isOk = ok === "true";
      const isInfo = ok === "info";
      const isSkip = ok === "skip";
      groups[g][key] = { ok: isOk, detail };
      if (isInfo) groups[g][key] = { info: true, detail };
      if (isSkip) groups[g][key] = { ok: null, skipped: true, detail };
      if (!isInfo && !isSkip) {
        total += 1;
        if (isOk) okCount += 1;
        else degraded.push(key);
      }
    }
    const out = {
      checked_at: new Date().toISOString(),
      session_id: sessionId || "unknown",
      schema_version: "1.0",
      summary: { ok: degraded.length === 0, passed: okCount, total, degraded },
      groups,
    };
    fs.writeFileSync(outFile, JSON.stringify(out, null, 2) + "\n");
    const tag = out.summary.ok ? "OK" : "DEGRADED";
    process.stderr.write(`VADE integrity: ${okCount}/${total} ${tag}`
      + (degraded.length ? ` — degraded (${degraded.join(",")})` : "")
      + ` — ${outFile}\n`);
  ' "$OUT_FILE" "${CLAUDE_CODE_SESSION_ID:-unknown}" || {
    echo "[vade-setup] integrity-check: node writer failed; leaving stale file" >&2
  }
else
  # Fallback: newline-separated triples, no JSON.
  {
    printf 'checked_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'session_id=%s\n' "${CLAUDE_CODE_SESSION_ID:-unknown}"
    printf '%s\n' "${RESULTS[@]}"
  } > "$OUT_FILE" 2>/dev/null || true
  echo "[vade-setup] integrity-check: node missing; wrote key=value file to $OUT_FILE" >&2
fi

exit 0
