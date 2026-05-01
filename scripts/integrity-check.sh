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

# Belt-and-suspenders: common.sh seeds VADE_CLOUD_STATE_DIR with a cloud-host default;
# session-start-sync.sh now merges it into settings.json so hooks inherit the correct path,
# but if that merge hasn't run yet (e.g., manual invocation before bootstrap), redirect
# when the cloud path is absent and the local path exists. vade-runtime#171.
if [ ! -d "$VADE_CLOUD_STATE_DIR" ] && [ -d "$HOME/.vade/local-state" ]; then
  VADE_CLOUD_STATE_DIR="$HOME/.vade/local-state"
fi

OUT_FILE="${VADE_CLOUD_STATE_DIR}/integrity-check.json"
RUNTIME_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Workspace root: parent of vade-runtime. /home/user on cloud,
# $WORKSPACE_ROOT (e.g. ~/GitHub/vade-app) on local. The cloud-style
# convenience symlinks (CLAUDE.md and .mcp.json) live here on both
# surfaces; deriving from SCRIPT_DIR keeps the invariants portable.
WORKSPACE_ROOT="$(cd "$RUNTIME_DIR/.." && pwd)"

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
# but the link is currently absent OR points at the wrong target → drift.
# A symlink pointing at the wrong place is just as bad as no symlink for
# the receipt's purposes (the receipt's invariant is "the workspace-scope
# overrides land where downstream consumers expect"), so we resolve and
# compare end targets rather than just checking existence. C1/C2 also
# validate the live targets in their own group; A3 specifically gates
# receipt-vs-reality drift between snapshot build and current resume.
A3_detail=""
A3_ok=true
if [ -f "$A1_receipt" ] && check_cmd node; then
  claim_mcp="$(node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1])); process.stdout.write(String(!!r.workspace_mcp_symlinked))' "$A1_receipt" 2>/dev/null || echo unknown)"
  claim_id="$(node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1])); process.stdout.write(String(!!r.identity_link_ok))' "$A1_receipt" 2>/dev/null || echo unknown)"
  expected_mcp_target="$(readlink -f "$WORKSPACE_ROOT/vade-runtime/.mcp.json" 2>/dev/null || true)"
  expected_id_target="$(readlink -f "$WORKSPACE_ROOT/vade-coo-memory/CLAUDE.md" 2>/dev/null || true)"
  observed_mcp=false; observed_id=false
  if [ -L "$WORKSPACE_ROOT/.mcp.json" ] && [ -n "$expected_mcp_target" ] \
     && [ "$(readlink -f "$WORKSPACE_ROOT/.mcp.json" 2>/dev/null)" = "$expected_mcp_target" ]; then
    observed_mcp=true
  fi
  if [ -L "$WORKSPACE_ROOT/CLAUDE.md" ] && [ -n "$expected_id_target" ] \
     && [ "$(readlink -f "$WORKSPACE_ROOT/CLAUDE.md" 2>/dev/null)" = "$expected_id_target" ]; then
    observed_id=true
  fi
  [ "$claim_mcp" = "$observed_mcp" ] || { A3_ok=false; A3_detail="mcp_link drift: receipt=$claim_mcp observed-correct-target=$observed_mcp; "; }
  [ "$claim_id" = "$observed_id" ] || { A3_ok=false; A3_detail="${A3_detail}identity_link drift: receipt=$claim_id observed-correct-target=$observed_id"; }
  [ "$A3_ok" = true ] && A3_detail="receipt matches observed (resolved) symlink targets"
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
for name in session-start-sync coo-bootstrap coo-identity-digest discussions-digest session-lifecycle session-idle-watchdog; do
  if ! [ -f "$RUNTIME_DIR/scripts/$name.sh" ]; then
    B1_ok=false
    B1_detail="${B1_detail}missing: $name.sh; "
  fi
done
[ "$B1_ok" = true ] && B1_detail="all 6 hook scripts present in runtime"
_add B1 "$B1_ok" "$B1_detail"

# B3: hook chain outcomes for the current session in boot.log.
# The prior implementation grepped /tmp/claude-code.log cumulatively,
# which (a) includes pre-fix historical failures forever and (b) over-
# matched 'No such file or directory' from unrelated subsystems (e.g.
# ripgrep probing a missing plugin cache). boot.log is per-hook-run
# structured JSON; scoping to the most recent cse_* session gives a
# current-state signal. Issue vade-runtime#41.
B3_ok=skip
B3_detail="boot.log not readable"
if [ -r "$HOME/.vade/boot.log" ]; then
  latest_session="$(grep -oE '"session":"cse_[^"]+' "$HOME/.vade/boot.log" 2>/dev/null | tail -1 | sed 's/^"session":"//')"
  if [ -n "$latest_session" ]; then
    failures="$(grep -F "\"session\":\"${latest_session}\"" "$HOME/.vade/boot.log" 2>/dev/null | grep -c '"ok":false' || true)"
    failures="${failures:-0}"
    if [ "$failures" -gt 0 ]; then
      B3_ok=false
      B3_detail="$failures failing hook entries in current session ($latest_session)"
    else
      B3_ok=true
      B3_detail="no hook failures in current session ($latest_session)"
    fi
  else
    B3_ok=true
    B3_detail="no tagged session in boot.log yet (pre-first-session)"
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
# Workspace-root convenience symlinks (CLAUDE.md, .mcp.json) live at
# $WORKSPACE_ROOT — /home/user on cloud, ~/GitHub/vade-app on local.
if [ -L "$WORKSPACE_ROOT/CLAUDE.md" ] && [ "$(readlink -f "$WORKSPACE_ROOT/CLAUDE.md")" = "$(readlink -f "$WORKSPACE_ROOT/vade-coo-memory/CLAUDE.md" 2>/dev/null)" ]; then
  _add C1 true "$WORKSPACE_ROOT/CLAUDE.md → vade-coo-memory/CLAUDE.md"
else
  _add C1 false "$WORKSPACE_ROOT/CLAUDE.md symlink missing or wrong target"
fi

if [ -L "$WORKSPACE_ROOT/.mcp.json" ] && [ "$(readlink -f "$WORKSPACE_ROOT/.mcp.json")" = "$(readlink -f "$WORKSPACE_ROOT/vade-runtime/.mcp.json" 2>/dev/null)" ]; then
  _add C2 true "$WORKSPACE_ROOT/.mcp.json → vade-runtime/.mcp.json"
else
  _add C2 false "$WORKSPACE_ROOT/.mcp.json symlink missing or wrong target"
fi

if [ -f "$WORKSPACE_ROOT/.mcp.json" ] && node -e 'JSON.parse(require("fs").readFileSync(process.argv[1]))' "$WORKSPACE_ROOT/.mcp.json" 2>/dev/null; then
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
  # 'SKIP marker present' is the idempotent-skip terminal written by
  # coo-bootstrap.sh when the marker file exists; it is a healthy
  # resumed-container outcome. Issue vade-runtime#41.
  if printf '%s' "$tail_line" | grep -qE 'OK step=complete|OK step=skip-|SKIP marker present'; then
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
    const req = ["GITHUB_MCP_PAT","GITHUB_TOKEN","AGENTMAIL_API_KEY","MEM0_API_KEY","VADE_CLOUD_STATE_DIR"];
    process.stdout.write(req.filter(k => !env[k]).join(","));
  ' "$HOME/.claude/settings.json" 2>/dev/null)"
  if [ -z "$D4_missing" ]; then
    _add D4 true "settings.json env has GITHUB_MCP_PAT, GITHUB_TOKEN, AGENTMAIL_API_KEY, MEM0_API_KEY, VADE_CLOUD_STATE_DIR"
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
  # Keys present; now check the signing posture is internally consistent.
  # Per MEMO 2026-04-23-04, cloud sessions (harness sets gpg.ssh.program
  # to a code-sign wrapper at /tmp/code-sign that substitutes the signing
  # key) must have commit.gpgsign=false and tag.gpgsign=false; Mac
  # sessions (no wrapper) must have both =true so the registered
  # vade-coo-sign key is actually used.
  D6_commit="$(git config --global commit.gpgsign 2>/dev/null || echo '<unset>')"
  D6_tag="$(git config --global tag.gpgsign 2>/dev/null || echo '<unset>')"
  if [ -x /tmp/code-sign ] || [ -n "${CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE:-}" ]; then
    if [ "$D6_commit" = "false" ] && [ "$D6_tag" = "false" ]; then
      _add D6 true "keys+signing-off (cloud, per MEMO 2026-04-23-04)"
    else
      _add D6 false "cloud harness detected but commit.gpgsign=$D6_commit tag.gpgsign=$D6_tag (expect false/false; MEMO 2026-04-23-04)"
    fi
  else
    if [ "$D6_commit" = "true" ] && [ "$D6_tag" = "true" ]; then
      _add D6 true "keys+signing-on (local, vade-coo-sign)"
    else
      _add D6 false "no harness but commit.gpgsign=$D6_commit tag.gpgsign=$D6_tag (expect true/true)"
    fi
  fi
else
  _add D6 false "vade-coo-{auth,sign} keys missing in $HOME/.ssh"
fi

# ── Group E: MCP surface ─────────────────────────────────────
# Requires MCP tool calls (get_me on github and github-coo namespaces).
# An agent invoking this directly should fill E1/E2/E3/E4 into the
# JSON afterwards. CI skips E1-E4 entirely. E5 is a script-level probe
# that doesn't require an agent — it spawns the stdio Mem0 MCP and
# confirms the JSON-RPC handshake.
_add E1 skip "requires-agent: call mcp__github__get_me (note: harness github MCP writes deny-listed in #112; reads only)"
_add E2 skip "github-coo MCP retired by Epic #112 Stream 1; vade-coo identity check is now \`gh auth status\` via Bash"
_add E3 skip "requires-agent: inspect mcp-needs-auth-cache.json"
_add E4 skip "requires-agent: observe tool namespaces"

# E5: stdio Mem0 MCP server is installed, answers initialize, AND
# completes a real tool round-trip against api.mem0.ai. The hosted
# https://mcp.mem0.ai endpoint hits a Node `undici` DNS-cache overflow
# inside Claude Code's MCP HTTP transport on cloud-harness boots
# (vade-runtime#36/#109), leaving the agent with no Mem0 surface for
# the rest of the session. We bypass that by running the official
# stdio MCP server (`mem0-mcp-server`, pinned via common.sh) as a
# subprocess.
#
# This probe layers two checks (per vade-runtime#114):
#   1. Transport — the binary spawns and answers initialize +
#      tools/list with the read/write tool surface we depend on.
#      Fast failure mode: missing binary, no MEM0_API_KEY, JSON-RPC
#      timeout, missing tool names.
#   2. API reachability — a real tools/call get_memories round-trip
#      that exercises api.mem0.ai. Without this, an
#      api.mem0.ai 503 ("DNS cache overflow") leaves initialize
#      passing while every actual tool call errors with
#      "Expecting value: line 1 column 1 (char 0)" — a misleading
#      green that defeats the point of `summary.ok`.
#
# Verdict ordering: handshake failure > round-trip failure > ok. The
# coo-identity-digest banner highlights any E* failure in the
# degraded block, so a degraded Mem0 surface is loud at SessionStart.
#
# Skip on CI (bootstrap-regression runs in fake-env mode against a
# mock workspace; live MCP probes can't validate there) and when the
# binary truly cannot be tested (no MEM0_API_KEY in env — the server
# won't accept initialize without auth). Live-only invariant; not part
# of the bootstrap-regression Layer-1 gate.
E5_ok=skip
E5_detail="requires mem0-mcp-server binary + MEM0_API_KEY"
_mem0_bin=""
for _candidate in "/home/user/.local/bin/mem0-mcp-server" "$HOME/.local/bin/mem0-mcp-server" "${VADE_BINDIR_OVERRIDE:-}/mem0-mcp-server"; do
  if [ -n "$_candidate" ] && [ -x "$_candidate" ]; then
    _mem0_bin="$_candidate"
    break
  fi
done

if [ -n "${VADE_CI_WORKSPACE_ROOT:-}" ] || [ -n "${VADE_BINDIR_OVERRIDE:-}" ]; then
  # CI mode: bootstrap-regression stages a fake-env workspace and the
  # live MCP install path is intentionally not exercised (would mean
  # a 50-package uv install on every PR run for a probe that can't
  # validate against the real api.mem0.ai anyway). Same shape as
  # E1-E4 above; skip cleanly.
  E5_ok=skip
  E5_detail="skipped in CI fake-env (VADE_CI_WORKSPACE_ROOT or VADE_BINDIR_OVERRIDE set); live-only probe"
elif [ -z "$_mem0_bin" ]; then
  E5_ok=false
  E5_detail="mem0-mcp-server binary missing; run ensure_mem0_mcp_server (cloud-setup.sh installs at build; session-start-sync.sh retries on resume)"
elif [ -z "${MEM0_API_KEY:-}" ]; then
  # Binary present but no key in process env. settings.json env will
  # populate it for Claude's MCP spawn, but the script itself runs in
  # a hook subprocess that may not have inherited yet. Treat as skip
  # rather than fail to avoid false negatives.
  E5_ok=skip
  E5_detail="mem0-mcp-server present at $_mem0_bin; MEM0_API_KEY not in hook env (cannot probe; settings.json env will populate at MCP spawn)"
elif ! check_cmd timeout || ! check_cmd node; then
  E5_ok=skip
  E5_detail="timeout or node missing; cannot probe"
else
  # Send initialize + initialized notification + tools/list +
  # tools/call get_memories, then read responses with a budgeted
  # timeout. The server emits one JSON-RPC line per response on
  # stdout. Success criteria:
  #   id=1 → result.serverInfo.name == "mem0"
  #   id=2 → result.tools contains get_memories + search_memories + add_memory
  #   id=3 → result returned without isError; round-trip to api.mem0.ai ok
  # Cheap filter: user_id="coo" with page_size=1 — tiny namespace,
  # one record, one network round-trip.
  E5_probe_out="$(
    {
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"integrity-check","version":"1.0"}}}'
      sleep 0.2
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
      sleep 0.1
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
      sleep 0.5
      printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_memories","arguments":{"filters":{"AND":[{"user_id":"coo"}]},"page":1,"page_size":1}}}'
      sleep 3
    } | MEM0_API_KEY="$MEM0_API_KEY" timeout 10 "$_mem0_bin" 2>/dev/null \
      | head -4
  )"
  E5_verdict="$(printf '%s' "$E5_probe_out" | node -e '
    let data = "";
    process.stdin.on("data", c => data += c);
    process.stdin.on("end", () => {
      const lines = data.split("\n").filter(Boolean);
      let serverName = null;
      let toolNames = [];
      let roundTripOk = false;
      let roundTripError = null;
      for (const l of lines) {
        try {
          const m = JSON.parse(l);
          if (m.id === 1 && m.result?.serverInfo?.name) serverName = m.result.serverInfo.name;
          if (m.id === 2 && Array.isArray(m.result?.tools)) toolNames = m.result.tools.map(t => t.name);
          if (m.id === 3) {
            if (m.error) {
              roundTripError = (m.error.message || JSON.stringify(m.error)).slice(0, 160);
            } else if (m.result?.isError) {
              const txt = m.result.content?.[0]?.text || JSON.stringify(m.result.content || m.result);
              roundTripError = ("isError: " + txt).slice(0, 160);
            } else if (m.result) {
              roundTripOk = true;
            }
          }
        } catch {}
      }
      const required = ["get_memories", "search_memories", "add_memory"];
      const missing = required.filter(n => !toolNames.includes(n));
      const handshakeOk = serverName === "mem0" && missing.length === 0;
      const out = {
        serverName,
        toolCount: toolNames.length,
        missing,
        handshakeOk,
        roundTripOk,
        roundTripError,
        ok: handshakeOk && roundTripOk,
      };
      process.stdout.write(JSON.stringify(out));
    });
  ' 2>/dev/null)"

  if [ -n "$E5_verdict" ] && printf '%s' "$E5_verdict" | grep -q '"ok":true'; then
    E5_ok=true
    E5_tools="$(printf '%s' "$E5_verdict" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const o=JSON.parse(d);process.stdout.write(o.toolCount+"")}catch{process.stdout.write("?")}})' 2>/dev/null || echo "?")"
    E5_detail="stdio Mem0 MCP healthy: $_mem0_bin (handshake ok, $E5_tools tools, get_memories round-trip ok)"
  else
    E5_ok=false
    if [ -z "$E5_probe_out" ]; then
      E5_detail="$_mem0_bin spawned but produced no JSON-RPC output in 10s; check MEM0_API_KEY validity, network egress to api.mem0.ai (curl https://api.mem0.ai/v1/ping/), and stderr"
    elif [ -z "$E5_verdict" ]; then
      E5_detail="$_mem0_bin probe parser produced no verdict; raw: $(printf '%s' "$E5_probe_out" | head -c 240)"
    elif printf '%s' "$E5_verdict" | grep -q '"handshakeOk":false'; then
      E5_detail="$_mem0_bin handshake failed: $(printf '%s' "$E5_verdict" | head -c 240)"
    else
      # Handshake passed but round-trip failed: api.mem0.ai is degraded
      # while the local MCP transport is up. This is the misleading-green
      # case from vade-runtime#114; surface it explicitly.
      _e5_rt_err="$(printf '%s' "$E5_verdict" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const o=JSON.parse(d);process.stdout.write(o.roundTripError||"(no error string)")}catch{process.stdout.write("(verdict parse failed)")}})' 2>/dev/null || echo "(node parse failed)")"
      E5_detail="api.mem0.ai unreachable: handshake ok but get_memories round-trip failed — $_e5_rt_err. Probe: curl https://api.mem0.ai/v1/ping/ ; if 503/DNS-cache-overflow, defer Mem0 writes (memo-sync, identity loads) until upstream recovers."
    fi
  fi
fi
_add E5 "$E5_ok" "$E5_detail"

# ── Group F: Culture-system substrate discipline ─────────────
# Implements E1–E4 from coo/foundations/2026-04-22_we-can-claim-a-record.md
# §5d (label delta: the essay calls these E1–E4; Group E is occupied by
# live MCP-surface probes, so the script reserves F). Adopted by
# SOP-CULTURE-001 and MEMO 2026-04-24-12. Non-fatal on every path.
#
# F_CUTOFF is the adoption moment from which the invariants bind.
# Artifacts dated earlier are pre-adoption and pass by construction.
# Bumping the cutoff requires a memo retiring or superseding MEMO
# 2026-04-24-12's §F_CUTOFF clause.
#
# Time-precise rather than date-precise because 2026-04-24 contained
# one Ven-authored commit (418f0a4, PR #94) an hour before the first
# decision-bearing commit of the day; an "adoption moment" captures
# the adoption boundary cleanly without retroactively flagging a
# legitimate pre-adoption attribution.
#
# F_CUTOFF_GIT bumped 2026-04-26 per MEMO 2026-04-26-01 to retire
# 7 chronic-yellow F4 hits (3 nightly-routine, 2 historical Ven-
# human-action quick-fixes, 1 post-convention quick-fix where the
# auto-marker workflow did not yet exist, 1 coo-scope refactor where
# the bootstrap was degraded at PR-open time). The auto-marker workflow
# in vade-coo-memory/.github/workflows/f4-marker.yml takes effect on
# PRs opened from this point forward; F4 reflects the post-workflow
# reality rather than the historical accumulation. F_CUTOFF (date form)
# stays at 2026-04-24 — F2/F3 are green and the broader memo/essay
# invariants should keep the wider window.
F_CUTOFF="2026-04-24"                     # date form — used for F2 memo-index, F3 essay-filename comparisons
F_CUTOFF_GIT="2026-04-26 00:30:00 +0000"  # timestamp form — used for F1/F4 git log --since

# Resolve the vade-coo-memory repo path. Canonical order: env
# override, sibling under WORKSPACE_ROOT (works on both cloud and
# local since WORKSPACE_ROOT was derived from SCRIPT_DIR above),
# macOS legacy fallback, cloud legacy fallback.
if [ -n "${COO_MEMORY_DIR:-}" ]; then
  F_REPO="$COO_MEMORY_DIR"
elif [ -d "$WORKSPACE_ROOT/vade-coo-memory" ]; then
  F_REPO="$WORKSPACE_ROOT/vade-coo-memory"
elif [ -d "$HOME/GitHub/vade-app/vade-coo-memory" ]; then
  F_REPO="$HOME/GitHub/vade-app/vade-coo-memory"
else
  F_REPO="/home/user/vade-coo-memory"
fi

# ── F1 — PR citation invariant ───────────────────────────────
# Every commit since F_CUTOFF touching coo/, identity/, context/, or
# CLAUDE.md (excluding _drafts/, _archive/, retrospectives/, and the
# foundations/*_transcript.md pattern) must cite MEMO YYYY-MM-DD-NN
# or #NNN in its message body. Diff mentions do not count.
if [ -d "$F_REPO/.git" ] && check_cmd git; then
  f1_total=0
  f1_bad=()
  # List commit SHAs touching F1 scope since F_CUTOFF; body inspection
  # happens per-commit. --name-only with --format gives sha-then-paths.
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    # Paths this commit touched that are in scope.
    touched=$(git -C "$F_REPO" show --name-only --format= "$sha" 2>/dev/null \
      | grep -E '^(coo/|identity/|context/|CLAUDE\.md$)' \
      | grep -vE '^coo/_drafts/|^coo/_archive/|^coo/_evidence/|^coo/retrospectives/|^coo/foundations/.*_transcript\.md$' \
      || true)
    [ -n "$touched" ] || continue
    f1_total=$((f1_total + 1))
    body=$(git -C "$F_REPO" log -1 --format='%B' "$sha" 2>/dev/null || echo '')
    if ! printf '%s' "$body" | grep -qE 'MEMO [0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]+|#[0-9]+'; then
      f1_bad+=("${sha:0:10}")
    fi
  done < <(git -C "$F_REPO" log --since="$F_CUTOFF_GIT" --format='%H' 2>/dev/null)

  if [ "$f1_total" -eq 0 ]; then
    _add F1 true "no decision-bearing commits since $F_CUTOFF_GIT (nothing to check)"
  elif [ "${#f1_bad[@]}" -eq 0 ]; then
    _add F1 true "$f1_total/$f1_total decision-bearing commits since $F_CUTOFF_GIT cite memo or issue"
  else
    _add F1 false "${#f1_bad[@]}/$f1_total commits missing citation: $(IFS=,; echo "${f1_bad[*]}")"
  fi
else
  _add F1 skip "requires coo-memory repo at $F_REPO with .git"
fi

# ── F2 — Memo retirement invariant ───────────────────────────
# Every memo dated >= F_CUTOFF in coo/memo_index.json must carry a
# 'Retirement condition' clause or `retention: "permanent"` in the body of
# its per-memo file at $entry.file_path (post-#210 layout, MEMO-2026-04-27-5kaq;
# canonical spec: coo/culture_system_sop.md F2 row).
# Absence = case-law violation per memo_protocol.md.
if [ -f "$F_REPO/coo/memo_index.json" ] && check_cmd jq; then
  f2_total=0
  f2_bad=()
  while IFS='|' read -r id fp; do
    [ -n "$id" ] || continue
    f2_total=$((f2_total + 1))
    body_path="$F_REPO/$fp"
    if [ ! -f "$body_path" ]; then
      f2_bad+=("$id(missing-file)")
      continue
    fi
    if ! grep -qE 'Retirement condition|retention: "permanent"' "$body_path"; then
      f2_bad+=("$id")
    fi
  done < <(jq -r --arg c "$F_CUTOFF" '.[] | select(.date >= $c) | "\(.id)|\(.file_path)"' "$F_REPO/coo/memo_index.json" 2>/dev/null)

  if [ "$f2_total" -eq 0 ]; then
    _add F2 true "no post-cutoff memos to check"
  elif [ "${#f2_bad[@]}" -eq 0 ]; then
    _add F2 true "$f2_total/$f2_total post-cutoff memos carry retirement clause"
  else
    _add F2 false "missing retirement clause: $(IFS=,; echo "${f2_bad[*]}")"
  fi
else
  _add F2 skip "requires coo/memo_index.json and jq"
fi

# ── F3 — Essay companion invariant ───────────────────────────
# Every coo/foundations/YYYY-MM-DD_*.md dated since F_CUTOFF (excluding
# _transcript and _agent-reports files) must have a matching
# YYYY-MM-DD_transcript.md companion in the same directory.
if [ -d "$F_REPO/coo/foundations" ]; then
  f3_total=0
  f3_bad=()
  while IFS= read -r essay; do
    [ -n "$essay" ] || continue
    essay_date="${essay:0:10}"
    # String comparison on ISO dates is safe; bash [[ ]] supports it.
    [ "$essay_date" \< "$F_CUTOFF" ] && continue
    case "$essay" in
      *_transcript.md|*_agent-reports*) continue ;;
    esac
    f3_total=$((f3_total + 1))
    if [ ! -f "$F_REPO/coo/foundations/${essay_date}_transcript.md" ]; then
      f3_bad+=("$essay")
    fi
  done < <(ls -1 "$F_REPO/coo/foundations/" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_')

  if [ "$f3_total" -eq 0 ]; then
    _add F3 true "no post-cutoff essays to check"
  elif [ "${#f3_bad[@]}" -eq 0 ]; then
    _add F3 true "$f3_total/$f3_total post-cutoff essays have transcript companion"
  else
    _add F3 false "missing transcript for: $(IFS=,; echo "${f3_bad[*]}")"
  fi
else
  _add F3 skip "no coo/foundations directory at $F_REPO"
fi

# ── F4 — Attribution coverage ────────────────────────────────
# Every commit since F_CUTOFF in $F_REPO must resolve to vade-coo
# (author email coo@vade-app.dev) or carry 'ven-human-action:' in body.
# Silent venpopov-authored commits on coo-scope paths are F4-relevant.
#
# F4_ALLOWLIST_SHA — explicit per-commit carve-outs where the marker
# was present in the PR body at merge time but the f4-marker workflow
# raced past a fast manual merge, leaving the commit body without the
# marker. Each entry must cite the originating PR + tracking issue.
# Tracked structurally at vade-coo-memory#271.
F4_ALLOWLIST_SHA=(
  # 0fd421a198 — vade-coo-memory#262 "add insight analysis" (Ven-
  # authored doc-add); PR body carries ven-human-action marker but
  # the merge stripped it. See vade-coo-memory#271 for the race fix.
  "0fd421a198"
)
if [ -d "$F_REPO/.git" ] && check_cmd git; then
  f4_total=0
  f4_bad=()
  while IFS='|' read -r sha email body; do
    # Skip blank records: awk's RS="\0" parser emits one on the trailing
    # null terminator, and trimmed SHA-less lines can slip through mid-stream.
    [ -n "$sha" ] || continue
    case "$sha" in *[!0-9a-f]*) continue ;; esac
    f4_total=$((f4_total + 1))
    if [ "$email" = "coo@vade-app.dev" ]; then
      continue
    fi
    if printf '%s' "$body" | grep -q 'ven-human-action:'; then
      continue
    fi
    allowed=0
    for allow_sha in "${F4_ALLOWLIST_SHA[@]}"; do
      case "$sha" in "$allow_sha"*) allowed=1; break ;; esac
    done
    [ "$allowed" -eq 1 ] && continue
    f4_bad+=("${sha:0:10}($email)")
  done < <(git -C "$F_REPO" log --since="$F_CUTOFF_GIT" --format='%H|%ae|%B%x00' 2>/dev/null | awk 'BEGIN{RS="\0"} { sub(/^\n/, ""); if (NF) { gsub(/\n/,"\\n"); print } }')

  if [ "$f4_total" -eq 0 ]; then
    _add F4 true "no commits since $F_CUTOFF_GIT (nothing to check)"
  elif [ "${#f4_bad[@]}" -eq 0 ]; then
    _add F4 true "$f4_total/$f4_total commits resolve to vade-coo or carry ven-human-action"
  else
    _add F4 false "${#f4_bad[@]}/$f4_total attribution mismatches: $(IFS=,; echo "${f4_bad[*]}")"
  fi
else
  _add F4 skip "requires coo-memory repo at $F_REPO with .git"
fi

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
