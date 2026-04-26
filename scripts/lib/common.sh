#!/usr/bin/env bash
# Shared functions for VADE environment setup scripts.
# Sourced by bootstrap.sh (devcontainer) and cloud-setup.sh (web).

log() { echo "[vade-setup] $*"; }

# Stderr-only variant so the message doesn't pollute stdout captures.
# Used inside retry loops where the caller wraps us in $(...) to grab
# a secret off stdout.
log_err() { echo "[vade-setup] $*" >&2; }

# Persistent bootstrap log. Every coo-bootstrap invocation appends one
# line with a timestamp, status (OK / FAIL / SKIP), and a short message.
# Identity-digest reads the tail of this file to surface the last
# outcome on each session start, so silent failures leave a trail.
COO_BOOTSTRAP_LOG="${HOME}/.vade/coo-bootstrap.log"

bootstrap_log_record() {
  local status="$1"; shift
  local message="$*"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$COO_BOOTSTRAP_LOG")" 2>/dev/null || return 0
  printf '%s %s %s\n' "$ts" "$status" "$message" >> "$COO_BOOTSTRAP_LOG" 2>/dev/null || return 0
  # Keep the log bounded. 200 lines is ~10 KB, plenty for recent history.
  if [ "$(wc -l < "$COO_BOOTSTRAP_LOG" 2>/dev/null || echo 0)" -gt 200 ]; then
    tail -n 200 "$COO_BOOTSTRAP_LOG" > "${COO_BOOTSTRAP_LOG}.tmp" 2>/dev/null \
      && mv -f "${COO_BOOTSTRAP_LOG}.tmp" "$COO_BOOTSTRAP_LOG" 2>/dev/null
  fi
}

# Durable cloud-state directory. Lives under /home/user/ so it survives
# the snapshot-build → session-resume transition; ~/.vade/ is under
# /root/ in the cloud image and gets fresh on every session boot, which
# is useful for session-scope logs but useless for recording what
# cloud-setup.sh actually did at build time. Keep session-scope state in
# ~/.vade/, snapshot-scope state here. Overridable so local-setup.sh
# can point it at ~/.vade/local-state on macOS.
VADE_CLOUD_STATE_DIR="${VADE_CLOUD_STATE_DIR:-/home/user/.vade-cloud-state}"
VADE_BUILD_LOG="${VADE_CLOUD_STATE_DIR}/build.log"
VADE_SETUP_RECEIPT="${VADE_CLOUD_STATE_DIR}/setup-receipt.json"

# Same shape as bootstrap_log_record but writes to the durable build log.
# Use from cloud-setup.sh and anything else running at snapshot-build
# time — PROBE entries, step transitions, timing — so sessions can
# diagnose "did build time actually run" without archaeology.
build_log_record() {
  local status="$1"; shift
  local message="$*"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! mkdir -p "$VADE_CLOUD_STATE_DIR" 2>/dev/null; then
    log "Warning: could not create $VADE_CLOUD_STATE_DIR; build log entry dropped"
    return 0
  fi
  if ! printf '%s %s %s\n' "$ts" "$status" "$message" >> "$VADE_BUILD_LOG" 2>/dev/null; then
    log "Warning: could not append to $VADE_BUILD_LOG; entry dropped"
    return 0
  fi
  if [ "$(wc -l < "$VADE_BUILD_LOG" 2>/dev/null || echo 0)" -gt 500 ]; then
    tail -n 500 "$VADE_BUILD_LOG" > "${VADE_BUILD_LOG}.tmp" 2>/dev/null \
      && mv -f "${VADE_BUILD_LOG}.tmp" "$VADE_BUILD_LOG" 2>/dev/null
  fi
}

# Per-session structured boot log. One JSON line per event, written by
# every SessionStart/Stop hook at key phases (start, major step, end).
# Lets integrity-check.sh reconstruct the boot timeline from a single
# file rather than correlating across claude-code.log, env-manager.log,
# and the per-script logs. Safe to call without node (pure printf).
#
# Usage:
#   boot_log_record session-start-sync start
#   boot_log_record session-start-sync sync_claude_config ok
#   boot_log_record session-start-sync end ok duration_ms=9
VADE_BOOT_LOG="${HOME}/.vade/boot.log"

# Minimal JSON-string escape: backslash, double-quote, and the four
# control chars that bash callers might plausibly pass (newline, CR,
# tab, backspace). Keeps each boot.log line a valid JSON object even
# when callers pass unescaped detail strings (e.g. shell command output,
# error messages with quotes).
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\b'/\\b}"
  printf '%s' "$s"
}

boot_log_record() {
  local script="$1" phase="$2"; shift 2
  local status="${1:-}"
  [ "$#" -gt 0 ] && shift
  local extras="" k v
  for kv in "$@"; do
    case "$kv" in
      *=*)
        k="$(_json_escape "${kv%%=*}")"
        v="$(_json_escape "${kv#*=}")"
        extras="$extras,\"$k\":\"$v\""
        ;;
    esac
  done
  local ts ok_field=""
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  case "$status" in
    ok|OK)   ok_field=',"ok":true' ;;
    fail|FAIL) ok_field=',"ok":false' ;;
    skip|SKIP) ok_field=',"ok":true,"skipped":true' ;;
    "")      ok_field='' ;;
    *)       ok_field=",\"status\":\"$(_json_escape "$status")\"" ;;
  esac
  mkdir -p "$(dirname "$VADE_BOOT_LOG")" 2>/dev/null || return 0
  printf '{"ts":"%s","session":"%s","script":"%s","phase":"%s"%s%s}\n' \
    "$ts" "$(_json_escape "${CLAUDE_CODE_SESSION_ID:-unknown}")" \
    "$(_json_escape "$script")" "$(_json_escape "$phase")" \
    "$ok_field" "$extras" \
    >> "$VADE_BOOT_LOG" 2>/dev/null || return 0
  # Bounded retention: 1000 lines ~ 100 KB, a few hundred sessions worth.
  if [ "$(wc -l < "$VADE_BOOT_LOG" 2>/dev/null || echo 0)" -gt 1000 ]; then
    tail -n 1000 "$VADE_BOOT_LOG" > "${VADE_BOOT_LOG}.tmp" 2>/dev/null \
      && mv -f "${VADE_BOOT_LOG}.tmp" "$VADE_BOOT_LOG" 2>/dev/null
  fi
}

# Write a JSON receipt at the end of cloud-setup.sh recording what
# succeeded. coo-identity-digest reads this to surface build-time state
# in the SessionStart digest block; missing file = cloud-setup didn't
# run (or failed before reaching the end). Accepts pairs of key=value
# args; values are emitted as booleans when "true"/"false", as numbers
# when all digits, as JSON strings otherwise.
#
# Usage:
#   build_receipt_write \
#     built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
#     op_token_visible=true \
#     coo_bootstrap_ran=false \
#     git_sha=abc123
build_receipt_write() {
  if ! mkdir -p "$VADE_CLOUD_STATE_DIR" 2>/dev/null; then
    log "Warning: could not create $VADE_CLOUD_STATE_DIR; setup-receipt skipped"
    return 0
  fi
  if ! check_cmd node; then
    log "Warning: node missing; writing receipt as plain key=value list"
    if ! printf '%s\n' "$@" > "$VADE_SETUP_RECEIPT" 2>/dev/null; then
      log "Warning: could not write $VADE_SETUP_RECEIPT; receipt skipped"
    fi
    return 0
  fi
  node -e '
    const fs = require("fs");
    const [dst, ...pairs] = process.argv.slice(1);
    const out = {};
    for (const p of pairs) {
      const eq = p.indexOf("=");
      if (eq < 0) continue;
      const k = p.slice(0, eq);
      const v = p.slice(eq + 1);
      if (v === "true") out[k] = true;
      else if (v === "false") out[k] = false;
      else if (/^-?\d+$/.test(v)) out[k] = Number(v);
      else out[k] = v;
    }
    fs.writeFileSync(dst, JSON.stringify(out, null, 2) + "\n");
  ' "$VADE_SETUP_RECEIPT" "$@" 2>/dev/null || {
    log "Warning: build_receipt_write via node failed; skipping"
    return 0
  }
  chmod 644 "$VADE_SETUP_RECEIPT" 2>/dev/null || true
}

# Retry a command with exponential backoff. Absorbs transient 1Password
# API failures (503s, network blips) that killed past bootstrap runs —
# one 503 on `op read` under `set -euo pipefail` was enough to bail the
# whole chain silently. Stdout of the successful attempt is passed
# through unchanged so callers can still do `x="$(retry 3 op read ref)"`.
# All log output goes to stderr.
#
# Usage: retry <tries> <cmd...>
#   retry 3 op read 'op://COO/foo/credential'
#   retry 3 op whoami >/dev/null
retry() {
  local tries="${1:-3}"
  shift
  local delay=1 attempt=0 rc=0
  local err_file
  err_file="$(mktemp 2>/dev/null)" || { "$@"; return $?; }
  while [ "$attempt" -lt "$tries" ]; do
    attempt=$((attempt+1))
    # Capture the actual exit of "$@" via `|| rc=$?`. The prior
    # `if "$@"; then ...; fi; rc=$?` pattern is a bash gotcha: after
    # an if-compound where no branch was taken, $? is 0, not the
    # failed command's exit. That made `retry` log rc=0 on every
    # retry line AND made `return "$rc"` after a full-failure loop
    # return 0, silently signalling success. Callers like `_op_to_file`
    # with `if ! content="$(retry 3 op read "$ref")"; then return 1`
    # never saw the failure: content came back empty, the ssh key
    # file got a bare newline, and install_coo_ssh_keys FATALed at
    # the fingerprint check instead of upstream at _op_to_file.
    # Witnessed on snapshot run-2026-04-22T091701.
    rc=0
    "$@" 2>"$err_file" || rc=$?
    if [ "$rc" -eq 0 ]; then
      rm -f "$err_file"
      return 0
    fi
    if [ "$attempt" -lt "$tries" ]; then
      log_err "  retry ${attempt}/${tries} for: $* (rc=$rc; sleeping ${delay}s)"
      sleep "$delay"
      delay=$((delay * 2))
    fi
  done
  local last_err
  last_err="$(tr '\n' ' ' < "$err_file" 2>/dev/null | cut -c1-240)"
  log_err "  FAIL after ${tries} attempts: $* (last err: ${last_err:-<empty>}; final rc=$rc)"
  cat "$err_file" >&2 2>/dev/null || true
  rm -f "$err_file"
  return "$rc"
}

# Pick up COO env vars (GITHUB_TOKEN, GITHUB_MCP_PAT, AGENTMAIL_API_KEY)
# if coo-bootstrap.sh has written them. No-op otherwise. Every script
# that sources common.sh benefits — this covers the case where a
# SessionStart hook subprocess needs those vars but didn't inherit
# them from Claude Code's own env (settings.json is read only at
# Claude Code startup, so the first session after provisioning has
# a gap that this closes).
# shellcheck source=/dev/null
[ -f "${HOME}/.vade/coo-env" ] && . "${HOME}/.vade/coo-env"

# Block until coo-bootstrap.sh reaches a terminal state (OK/FAIL/SKIP)
# in this session, then re-source coo-env so vars written during the
# wait land in the calling process. SessionStart hooks run in parallel,
# so any hook that consumes GITHUB_TOKEN / GITHUB_MCP_PAT / AGENTMAIL_API_KEY
# (e.g. discussions-digest, coo-identity-digest's posture block) would
# otherwise sample before bootstrap finishes and falsely report
# "unset / degraded". Fast-exits after a 2s grace if no coo-bootstrap.sh
# process is running (covers standalone invocations, hook disabled,
# and bootstrap-already-finished cases).
#
# Args: $1 = timeout in seconds (default 60)
# Exposes:
#   VADE_BOOTSTRAP_WAIT_SAW_FRESH  — 1 if a fresh terminal state was seen, else 0
#   VADE_BOOTSTRAP_WAIT_ELAPSED    — seconds actually waited
#   VADE_BOOTSTRAP_WAIT_TIMEOUT    — configured timeout
# Always returns 0.
wait_for_coo_bootstrap() {
  local timeout="${1:-60}"
  local bootstrap_log="${HOME}/.vade/coo-bootstrap.log"
  local start_epoch elapsed=0
  start_epoch="$(date -u +%s)"
  VADE_BOOTSTRAP_WAIT_SAW_FRESH=0
  VADE_BOOTSTRAP_WAIT_TIMEOUT="$timeout"
  while [ "$elapsed" -lt "$timeout" ]; do
    if [ -f "$bootstrap_log" ]; then
      local last_line last_ts last_state last_epoch
      last_line="$(tail -n 1 "$bootstrap_log" 2>/dev/null || true)"
      last_ts="${last_line%% *}"
      last_state="$(printf '%s' "$last_line" | awk '{print $2}')"
      case "$last_state" in
        OK|FAIL|SKIP)
          # Portable ISO-8601 → epoch via node (already a hard dep of
          # the digest scripts; `date -d` is GNU-only).
          last_epoch="$(node -e 'const t=Date.parse(process.argv[1]); process.stdout.write(isNaN(t)?"0":String(Math.floor(t/1000)))' "$last_ts" 2>/dev/null || echo 0)"
          if [ "$last_epoch" -ge "$start_epoch" ]; then
            VADE_BOOTSTRAP_WAIT_SAW_FRESH=1
            break
          fi
          ;;
      esac
    fi
    if [ "$elapsed" -ge 2 ] && ! pgrep -f coo-bootstrap.sh >/dev/null 2>&1; then
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  VADE_BOOTSTRAP_WAIT_ELAPSED="$elapsed"
  # shellcheck source=/dev/null
  [ -f "${HOME}/.vade/coo-env" ] && . "${HOME}/.vade/coo-env"
  return 0
}

check_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ensure_dirs() {
  mkdir -p "$HOME/.vade/library/canvases" \
           "$HOME/.vade/library/entities" 2>/dev/null || \
    log "Warning: could not create $HOME/.vade subdirs. Check permissions."
}

ensure_tsx() {
  if check_cmd tsx; then
    log "tsx already installed: $(tsx --version 2>&1 | head -1)"
    return 0
  fi
  log "Installing tsx globally..."
  npm install -g tsx@4.21.0 --no-audit --no-fund
}

install_deps() {
  local dir="${1:-.}"
  if [ -f "$dir/package.json" ]; then
    log "Installing npm dependencies in $dir..."
    (cd "$dir" && npm install --no-audit --no-fund)
  fi
}

# Mirror the committed .claude/ directory into Claude Code's user-scope
# config dir. Subdirs (skills/, agents/, commands/, hooks/) are
# symlinked so edits in the repo are live next SessionStart.
# settings.json is copied so coo-bootstrap can mutate the env block
# without dirtying the git working tree. Plans/, projects/, todos/,
# statsig/ and other Claude Code-managed dirs are left alone.
#
# Subdir strategy: Claude Code itself ships some of these dirs
# pre-populated (e.g. ~/.claude/skills/session-start-hook/). Replacing
# a real directory with a symlink via `ln -snf` silently nests
# instead, so when the destination already exists as a real dir we
# merge per-entry: each source child is symlinked in alongside the
# built-ins. Name collisions with a built-in are skipped with a
# warning rather than clobbered.
#
# settings.json: the source tree's copy is the source of truth for
# hooks and other top-level keys, but the destination's `.env` is
# populated at runtime by coo-bootstrap and must survive a re-sync
# (coo-bootstrap's idempotency marker short-circuits re-merging on
# subsequent runs). We preserve dest env via a node-based merge when
# both files exist; otherwise we fall back to a plain copy.
sync_claude_config() {
  local src="${1:-/home/user/vade-runtime/.claude}"
  local dst="${2:-$HOME/.claude}"
  if [ ! -d "$src" ]; then
    log "sync_claude_config: source $src missing; skipping"
    return 0
  fi
  mkdir -p "$dst"
  for sub in skills agents commands hooks; do
    [ -d "$src/$sub" ] || continue
    _sync_claude_subdir "$src/$sub" "$dst/$sub"
  done
  if [ -f "$src/settings.json" ]; then
    _sync_claude_settings "$src/settings.json" "$dst/settings.json"
  fi
  # settings.json hooks reference $HOME/.claude/vade-hooks/dispatch.sh;
  # install the shim alongside settings.json so both land atomically
  # from a single sync_claude_config call.
  ensure_hooks_dispatch_shim "$src" "$dst"
  log "Synced $src → $dst (subdirs symlinked, settings.json copied, dispatch shim installed)"
}

# Install $HOME/.claude/vade-hooks/dispatch.sh pointing at the runtime
# repo's hooks-dispatch.sh. Called from sync_claude_config, so every
# build-time and session-start sync refreshes the shim — it self-heals
# if the snapshot is stale or the target moved.
#
# The source is derived from the passed-in .claude dir, not hardcoded,
# so local-setup.sh's custom runtime path works without extra plumbing.
# Idempotent: if the symlink already points at the right target, no-op.
ensure_hooks_dispatch_shim() {
  local claude_src="$1" claude_dst="$2"
  local runtime_src shim_src shim_dst
  runtime_src="$(cd "$claude_src/.." 2>/dev/null && pwd)"
  shim_src="$runtime_src/scripts/hooks-dispatch.sh"
  shim_dst="$claude_dst/vade-hooks/dispatch.sh"
  if [ ! -f "$shim_src" ]; then
    log "hooks-dispatch: source $shim_src missing; skipping"
    return 0
  fi
  mkdir -p "$(dirname "$shim_dst")"
  if [ -L "$shim_dst" ] && [ "$(readlink -f "$shim_dst" 2>/dev/null)" = "$(readlink -f "$shim_src" 2>/dev/null)" ]; then
    return 0
  fi
  if [ -e "$shim_dst" ] && [ ! -L "$shim_dst" ]; then
    log "hooks-dispatch: $shim_dst exists and is not a symlink; leaving it alone"
    return 0
  fi
  ln -snf "$shim_src" "$shim_dst"
  log "hooks-dispatch: linked $shim_dst → $shim_src"
}

_sync_claude_subdir() {
  local src_sub="$1" dst_sub="$2"
  if [ -L "$dst_sub" ] || [ ! -e "$dst_sub" ]; then
    ln -snf "$src_sub" "$dst_sub"
    return 0
  fi
  # Destination exists as a real directory (e.g. Claude Code built-in
  # skills). Merge per-entry so both coexist.
  local entry name target
  for entry in "$src_sub"/*; do
    [ -e "$entry" ] || continue
    name="$(basename "$entry")"
    target="$dst_sub/$name"
    if [ -e "$target" ] && [ ! -L "$target" ]; then
      log "  warn: $target exists and is not a symlink; skipping to avoid clobbering built-in"
      continue
    fi
    ln -snf "$entry" "$target"
  done
}

# Aggregate per-repo .claude/{commands,agents,skills,hooks} into the
# workspace .claude/ via per-file symlinks.
#
# Why: under the data-ownership rule (MEMO 2026-04-25-02), slash
# commands and skills live in the repo whose data they manipulate
# (e.g. /memo-query in vade-coo-memory). For Ven to invoke them
# regardless of which repo he launched Claude Code from, the workspace
# .claude/ must surface every per-repo primitive in one place. This
# function does that with per-file symlinks — Claude Code resolves the
# symlink and finds the command in its source repo, no copy drift.
#
# Conflict policy: first-source-wins (sources are walked in arg order).
# Conflicts are logged but don't fail. Real-file conflicts (a non-symlink
# at the destination) are skipped to avoid clobbering harness built-ins.
#
# Usage: aggregate_workspace_claude_config <workspace_root> <dst_root> <repo1> [repo2] ...
#   workspace_root  — directory containing the repo dirs (e.g. /home/user
#                     on cloud, ~/GitHub/vade-app on local).
#   dst_root        — where the aggregated .claude/ should land. On cloud
#                     this is $HOME/.claude (user-scope); on local this is
#                     $WORKSPACE_ROOT/.claude (project-scope).
aggregate_workspace_claude_config() {
  local workspace_root="$1"; shift
  local dst_root="$1"; shift
  mkdir -p "$dst_root"
  local sub
  for sub in commands agents skills hooks; do
    local dst_sub="$dst_root/$sub"
    # If dst is a symlink (legacy single-source layout), materialize it
    # into a real directory so we can union multiple sources into it.
    if [ -L "$dst_sub" ]; then
      local prev_target; prev_target="$(readlink -f "$dst_sub" 2>/dev/null || true)"
      rm "$dst_sub"
      mkdir -p "$dst_sub"
      if [ -n "$prev_target" ] && [ -d "$prev_target" ]; then
        local prev_entry prev_name
        for prev_entry in "$prev_target"/*; do
          [ -e "$prev_entry" ] || continue
          prev_name="$(basename "$prev_entry")"
          ln -snf "$prev_entry" "$dst_sub/$prev_name"
        done
      fi
    else
      mkdir -p "$dst_sub"
    fi
    local repo src entry name target
    for repo in "$@"; do
      src="$workspace_root/$repo/.claude/$sub"
      [ -d "$src" ] || continue
      for entry in "$src"/*; do
        [ -e "$entry" ] || continue
        name="$(basename "$entry")"
        target="$dst_sub/$name"
        if [ -L "$target" ]; then
          local cur; cur="$(readlink -f "$target" 2>/dev/null || true)"
          local want; want="$(readlink -f "$entry" 2>/dev/null || true)"
          [ "$cur" = "$want" ] && continue
          # First-source-wins; later repo skipped with note.
          log "  aggregate: $sub/$name conflict; keeping $cur, skipping $want"
          continue
        fi
        if [ -e "$target" ] && [ ! -L "$target" ]; then
          log "  warn: $target exists and is not a symlink; skipping"
          continue
        fi
        ln -snf "$entry" "$target"
      done
    done
  done
  log "Aggregated workspace .claude/ from: $*"
}

_sync_claude_settings() {
  local src_file="$1" dst_file="$2"
  if [ -f "$dst_file" ] && check_cmd node; then
    if node -e '
      const fs = require("fs");
      const [srcPath, dstPath] = process.argv.slice(1);
      const src = JSON.parse(fs.readFileSync(srcPath, "utf8"));
      let dstEnv = {};
      try {
        const dst = JSON.parse(fs.readFileSync(dstPath, "utf8")) || {};
        dstEnv = dst.env || {};
      } catch {}
      const merged = Object.assign({}, src);
      merged.env = Object.assign({}, src.env || {}, dstEnv);
      fs.writeFileSync(dstPath, JSON.stringify(merged, null, 2) + "\n");
    ' "$src_file" "$dst_file" 2>/dev/null; then
      chmod 600 "$dst_file"
      return 0
    fi
    log "  warn: settings.json merge via node failed; falling back to plain copy"
  fi
  cp -f "$src_file" "$dst_file"
  chmod 600 "$dst_file"
}

# Ensure /home/user/.mcp.json is a symlink to the runtime repo's
# .mcp.json. Claude Code loads project-scope .mcp.json from its cwd,
# and in the cloud env cwd is /home/user, which has no .mcp.json of
# its own — so project MCPs stay dark even when env vars are populated.
# Symlinking to vade-runtime/.mcp.json fixes this and keeps a single
# source of truth: the same file loads at cwd=/home/user (via symlink)
# and at cwd=/home/user/vade-runtime (natively). Before MEMO 2026-04-22-08
# the shared config lived in a separate workspace-mcp.json; the two
# were unified.
# Idempotent: if the symlink already points at the right target, no-op.
ensure_workspace_mcp_config() {
  local src="${1:-/home/user/vade-runtime/.mcp.json}"
  local dst="${2:-/home/user/.mcp.json}"
  if [ ! -f "$src" ]; then
    log "mcp-link: source $src missing; skipping"
    return 0
  fi
  if [ -L "$dst" ] && [ "$(readlink -f "$dst" 2>/dev/null)" = "$(readlink -f "$src" 2>/dev/null)" ]; then
    return 0
  fi
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    log "mcp-link: $dst exists and is not a symlink; leaving it alone"
    return 0
  fi
  ln -snf "$src" "$dst"
  log "mcp-link: linked $dst → $src"
}

# Ensure /home/user/CLAUDE.md symlinks to vade-coo-memory/CLAUDE.md so
# Claude Code's built-in memory auto-loader picks up the COO identity
# instructions at session start (cwd=/home/user). Without this,
# identity surfaces only via coo-identity-digest's echo, which fires
# after MCP resolution and isn't visible to the harness memory system.
# Idempotent, mirrors ensure_workspace_mcp_config's guards.
ensure_workspace_identity_link() {
  local src="${1:-/home/user/vade-coo-memory/CLAUDE.md}"
  local dst="${2:-/home/user/CLAUDE.md}"
  if [ ! -f "$src" ]; then
    log "identity-link: source $src missing; skipping"
    return 0
  fi
  if [ -L "$dst" ] && [ "$(readlink -f "$dst" 2>/dev/null)" = "$(readlink -f "$src" 2>/dev/null)" ]; then
    return 0
  fi
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    log "identity-link: $dst exists and is not a symlink; leaving it alone"
    return 0
  fi
  ln -snf "$src" "$dst"
  log "identity-link: linked $dst → $src"
}

print_versions() {
  local tsx_version claude_version

  if check_cmd tsx; then
    tsx_version="$(tsx --version 2>/dev/null | head -1)"
  else
    tsx_version="$(npx tsx --version 2>/dev/null | head -1 || true)"
    [ -n "$tsx_version" ] || tsx_version="not found"
  fi

  if check_cmd claude; then
    claude_version="$(claude --version 2>/dev/null || true)"
    if [ -n "$claude_version" ]; then
      claude_version="$claude_version (run: claude login if needed)"
    else
      claude_version="available (run: claude login)"
    fi
  else
    claude_version="not available"
  fi

  log "Tool versions:"
  log "  node: $(node --version 2>/dev/null || echo 'not found')"
  log "  npm:  $(npm --version 2>/dev/null || echo 'not found')"
  log "  git:  $(git --version 2>/dev/null || echo 'not found')"
  log "  tsx:  $tsx_version"
  log "  claude: $claude_version"
}

# ===== COO identity bootstrap helpers =====
# Used by scripts/coo-bootstrap.sh when OP_SERVICE_ACCOUNT_TOKEN is set.
# Fetch COO identity material from a 1Password vault named "COO" via the
# op CLI. Vault/item contract and the cloud-env boot flow are documented
# in vade-coo-memory/coo/cloud-env-bootstrap.md.

OP_VERSION_DEFAULT="2.31.0"
GH_VERSION_DEFAULT="2.91.0"
COO_AUTH_FP_EXPECTED="SHA256:9vxJc6c69L8eaR6CvwdZoYDco24W6yN6GkKwnsm8Uys"
COO_SIGN_FP_EXPECTED="SHA256:pZeA8xycAtIsVGwhMzR3mg4KG05n9ksFuy4F1ZVXn3A"

# Snapshot-persistent user bindir. Cloud harness runs as root and the
# /home/user/ tree survives snapshot → resume; local Mac has no
# /home/user/ and runs as the operator's user, so $HOME/.local/bin is
# the right target. Both ensure_op_cli and ensure_gh_cli install here.
_snapshot_user_bindir() {
  if [ "$(id -u)" = "0" ] && [ -d /home/user ]; then
    printf '/home/user/.local/bin'
  else
    printf '%s/.local/bin' "$HOME"
  fi
}

ensure_op_cli() {
  # Install into a snapshot-persistent path so a build-time install is
  # still on disk at session-resume time. /root/ resets each resume in
  # the cloud image; /home/user/ survives the snapshot. Without this,
  # the SessionStart-hook bootstrap fallback has to re-fetch op from
  # cache.agilebits.com mid-session and dies whenever Anthropic's
  # egress proxy is flaky (see run-2026-04-22T062313 and
  # run-2026-04-22T213126: "DNS cache overflow" 503 from the egress
  # gateway, both times).
  #
  # Linux-only auto-install. On macOS (Darwin) the expectation is that
  # `brew install 1password-cli` has already satisfied check_cmd; if it
  # hasn't, this function refuses rather than dropping a non-runnable
  # Linux binary into ${HOME}/.local/bin (vade-runtime#81).
  local bindir
  bindir="$(_snapshot_user_bindir)"
  case ":$PATH:" in
    *":$bindir:"*) ;;
    *) export PATH="$bindir:$PATH" ;;
  esac

  if check_cmd op; then
    log "op CLI present: $(op --version 2>&1 | head -1)"
    return 0
  fi

  local os
  os="$(uname -s)"
  case "$os" in
    Linux) ;;
    Darwin)
      log "op CLI not present on macOS; install via: brew install 1password-cli"
      return 1
      ;;
    *)
      log "op CLI: unsupported OS '$os'"
      return 1
      ;;
  esac

  local version="${OP_VERSION:-$OP_VERSION_DEFAULT}"
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) log "op CLI: unsupported arch '$arch'"; return 1 ;;
  esac

  mkdir -p "$bindir"

  local url="https://cache.agilebits.com/dist/1P/op2/pkg/v${version}/op_linux_${arch}_v${version}.zip"
  local tmp
  tmp="$(mktemp -d)"
  log "Downloading op CLI v${version} (${arch}) → $bindir"
  # cache.agilebits.com occasionally returns 5xx; retry absorbs the
  # transient window. 5 attempts (~15s tolerance) matches _op_to_file's
  # already-tuned budget (line ~942) — same egress origin class, same
  # flake pattern. Witnessed exhaustion of the prior 3-attempt budget
  # in run-2026-04-25T182206; #76 propagates the proven budget here.
  if ! retry 5 curl -sfL "$url" -o "$tmp/op.zip"; then
    log "op CLI download failed after retries: $url"
    rm -rf "$tmp"
    return 1
  fi

  if check_cmd unzip; then
    unzip -qo "$tmp/op.zip" -d "$tmp"
  elif check_cmd python3; then
    python3 -m zipfile -e "$tmp/op.zip" "$tmp"
  else
    log "op CLI extraction failed: need 'unzip' or 'python3'."
    rm -rf "$tmp"
    return 1
  fi

  install -m 0755 "$tmp/op" "$bindir/op"
  rm -rf "$tmp"

  if ! op --version >/dev/null 2>&1; then
    log "op CLI install appears broken"
    return 1
  fi
  log "Installed op CLI: $(op --version 2>&1 | head -1)"
}

# Durable GitHub write path for COO attribution.
#
# Installs the gh CLI into a snapshot-persistent path under the user's
# .local/bin (/home/user/.local/bin when running as root with a
# /home/user tree — cloud harness; ${HOME}/.local/bin otherwise) so it
# survives the snapshot → resume transition with no per-resume fetch.
# check_cmd gh short-circuits when gh is already present (local macOS
# via brew, devcontainer pre-install, or a prior build).
#
# Linux-only auto-install. On macOS (Darwin) the expectation is that
# `brew install gh` has already satisfied check_cmd; if it hasn't, this
# function refuses rather than dropping a non-runnable Linux binary
# into ${HOME}/.local/bin. Bindir resolution is shared with ensure_op_cli
# via _snapshot_user_bindir.
#
# Rationale: vade-app/vade-runtime#36 documents the mcp__github-coo__*
# streamable-HTTP transport failure ("DNS cache overflow") that forces
# attribution to fall through to venpopov via mcp__github__* when the
# MCP is degraded. `gh` authenticated with $GITHUB_MCP_PAT preserves
# vade-coo opener attribution under the same PAT, via short-lived HTTPS
# request/response cycles that bypass the failing transport. Same token,
# same identity, different wire — MEMO 2026-04-22-04 attribution
# invariant stays load-bearing even when the primary MCP is down.
ensure_gh_cli() {
  local bindir
  bindir="$(_snapshot_user_bindir)"
  case ":$PATH:" in
    *":$bindir:"*) ;;
    *) export PATH="$bindir:$PATH" ;;
  esac

  if check_cmd gh; then
    log "gh CLI present: $(gh --version 2>&1 | head -1)"
    return 0
  fi

  local os
  os="$(uname -s)"
  case "$os" in
    Linux) ;;
    Darwin)
      log "gh CLI not present on macOS; install via: brew install gh"
      return 1
      ;;
    *)
      log "gh CLI: unsupported OS '$os'"
      return 1
      ;;
  esac

  local version="${GH_VERSION:-$GH_VERSION_DEFAULT}"
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) log "gh CLI: unsupported arch '$arch'"; return 1 ;;
  esac

  mkdir -p "$bindir"

  local url="https://github.com/cli/cli/releases/download/v${version}/gh_${version}_linux_${arch}.tar.gz"
  local tmp
  tmp="$(mktemp -d)"
  log "Downloading gh CLI v${version} (${os}/${arch}) → $bindir"
  if ! retry 3 curl -sfL "$url" -o "$tmp/gh.tar.gz"; then
    log "gh CLI download failed after retries: $url"
    rm -rf "$tmp"
    return 1
  fi

  if ! tar -xzf "$tmp/gh.tar.gz" -C "$tmp"; then
    log "gh CLI extraction failed"
    rm -rf "$tmp"
    return 1
  fi

  local gh_bin
  gh_bin="$(find "$tmp" -type f -name gh -path '*/bin/gh' | head -1)"
  if [ -z "$gh_bin" ] || [ ! -f "$gh_bin" ]; then
    log "gh CLI: extracted tarball missing bin/gh"
    rm -rf "$tmp"
    return 1
  fi
  install -m 0755 "$gh_bin" "$bindir/gh"
  rm -rf "$tmp"

  if ! gh --version >/dev/null 2>&1; then
    log "gh CLI install appears broken"
    return 1
  fi
  log "Installed gh CLI: $(gh --version 2>&1 | head -1)"
}

# Expose gh on Claude Code's Bash-tool PATH every session.
#
# ensure_gh_cli installs to /home/user/.local/bin so the binary survives
# cloud snapshot rebuilds, but the shell Claude spawns only has
# /root/.local/bin on PATH. Bridge the two with a symlink so `gh`
# resolves without the agent having to mutate PATH or discover the
# install path. Cloud-only (root + /home/user present); on macOS/local
# gh comes from brew and $HOME/.local/bin is already on PATH.
# Idempotent via ln -sfn; no-op with a quiet log if the target is
# missing (ensure_gh_cli is the installer).
ensure_gh_symlink_on_path() {
  [ "$(id -u)" = "0" ] && [ -d /home/user ] || return 0
  local target="/home/user/.local/bin/gh"
  local link="/root/.local/bin/gh"
  if [ ! -x "$target" ]; then
    log "gh symlink: $target missing; skipping (run ensure_gh_cli to install)"
    return 0
  fi
  mkdir -p "$(dirname "$link")"
  ln -sfn "$target" "$link"
}

# Install the gh-coo-wrap wrapper at /home/user/.local/bin/gh so every
# attributable `gh` write auto-carries the Claude Code session URL.
# Substrate enforcement of vade-coo-memory MEMO 2026-04-26-02 (issue
# #150). The real gh binary moves to /home/user/.local/bin/gh-real;
# the wrapper exec's it after augmenting --body / --body-file.
#
# Idempotent: subsequent runs detect the wrapper marker and only
# refresh the wrapper content (in case the source script has been
# updated). Cloud-only path guard (root + /home/user); macOS/local
# uses brew gh and is left untouched.
ensure_gh_coo_wrap() {
  [ "$(id -u)" = "0" ] && [ -d /home/user ] || return 0
  local gh_path="/home/user/.local/bin/gh"
  local real_path="/home/user/.local/bin/gh-real"
  local wrapper_src="${1:-}"
  if [ -z "$wrapper_src" ] || [ ! -f "$wrapper_src" ]; then
    log "gh-coo-wrap: source script missing; skipping"
    return 0
  fi
  if [ ! -x "$gh_path" ]; then
    log "gh-coo-wrap: $gh_path missing; skipping (ensure_gh_cli installs gh)"
    return 0
  fi
  if grep -q 'COO-GH-COO-WRAP-MARKER-v1' "$gh_path" 2>/dev/null; then
    # Wrapper already installed — refresh content in case the source has changed.
    install -m 0755 "$wrapper_src" "$gh_path"
    return 0
  fi
  # First-time install: rename real binary and place wrapper.
  if [ ! -x "$real_path" ]; then
    mv "$gh_path" "$real_path"
  else
    # Real binary already present (recovery from a partial state):
    # back up whatever is at gh_path and replace with the wrapper.
    rm -f "$gh_path"
  fi
  install -m 0755 "$wrapper_src" "$gh_path"
  log "gh-coo-wrap: installed (wrapper at $gh_path, real binary at $real_path)"
}

# Fetch COO secrets from 1Password and write ~/.vade/coo-env plus a
# merged env block in ~/.claude/settings.json so Claude Code resolves
# ${GITHUB_MCP_PAT} / ${AGENTMAIL_API_KEY} at startup. Each read is
# independent — a missing item logs a warning and leaves the
# corresponding env var unset rather than aborting. Callers that
# depend on a specific var (e.g. validate_coo_identity needs
# GITHUB_MCP_PAT) are responsible for their own presence check.
# Returns 0 if at least one secret was fetched; 1 only if every
# read failed.
fetch_coo_secrets() {
  log "Fetching COO secrets from 1Password vault COO"
  local github_pat="" agentmail_key="" mem0_key=""
  local got=0

  if github_pat="$(retry 3 op read 'op://COO/vade-coo-self-2026-04/token')" && [ -n "$github_pat" ]; then
    log "  read GitHub PAT (len=${#github_pat})"
    got=$((got+1))
  else
    github_pat=""
    log "  WARN: op://COO/vade-coo-self-2026-04/token unavailable; GITHUB_MCP_PAT/GITHUB_TOKEN will be unset"
  fi

  if agentmail_key="$(retry 3 op read 'op://COO/agentmail-vade-coo/credential')" && [ -n "$agentmail_key" ]; then
    log "  read AgentMail API key (len=${#agentmail_key})"
    got=$((got+1))
  else
    agentmail_key=""
    log "  WARN: op://COO/agentmail-vade-coo/credential unavailable; AGENTMAIL_API_KEY will be unset"
  fi

  if mem0_key="$(retry 3 op read 'op://COO/mem0-vade-coo/credential')" && [ -n "$mem0_key" ]; then
    log "  read Mem0 API key (len=${#mem0_key})"
    got=$((got+1))
  else
    mem0_key=""
    log "  WARN: op://COO/mem0-vade-coo/credential unavailable; MEM0_API_KEY will be unset (mem0-rest.sh break-glass path disabled)"
  fi

  if [ "$got" -eq 0 ]; then
    log "  no COO secrets could be fetched; skipping env file write"
    return 1
  fi

  local env_file="${HOME}/.vade/coo-env"
  mkdir -p "$(dirname "$env_file")"
  (
    umask 077
    {
      echo "# Auto-generated by coo-bootstrap.sh. Do not commit. chmod 600."
      [ -n "$github_pat" ]    && echo "export GITHUB_MCP_PAT='$github_pat'"
      [ -n "$github_pat" ]    && echo "export GITHUB_TOKEN='$github_pat'"
      [ -n "$agentmail_key" ] && echo "export AGENTMAIL_API_KEY='$agentmail_key'"
      [ -n "$mem0_key" ]      && echo "export MEM0_API_KEY='$mem0_key'"
    } > "$env_file"
  )
  chmod 600 "$env_file"
  log "  wrote $env_file (0600)"

  # Export to current shell so validate_coo_identity (which reads
  # $GITHUB_MCP_PAT) sees the freshly-fetched PAT. settings.json mutation
  # happens later in merge_coo_settings_env, only after validation
  # passes — see #66 (env-merge-before-validate).
  [ -n "$github_pat" ]    && export GITHUB_MCP_PAT="$github_pat" GITHUB_TOKEN="$github_pat"
  [ -n "$agentmail_key" ] && export AGENTMAIL_API_KEY="$agentmail_key"
  [ -n "$mem0_key" ]      && export MEM0_API_KEY="$mem0_key"
  return 0
}

# Merge the (now-validated) COO env into ~/.claude/settings.json. Called
# from coo-bootstrap.sh AFTER validate_coo_identity, so a wrong-identity
# PAT never lands in the harness's persistent state. Reads from the
# already-exported environment populated by fetch_coo_secrets — keeps
# the call symmetric with the shell-export step there. See #66 for
# the env-merge-before-validate failure mode this ordering closes.
merge_coo_settings_env() {
  _write_claude_settings_env \
    "${GITHUB_MCP_PAT:-}" \
    "${AGENTMAIL_API_KEY:-}" \
    "${MEM0_API_KEY:-}"
}

# Persist non-secret bootstrap-derived path state into ~/.claude/settings.json
# env so every shell the harness spawns (sub-agents, Bash tool calls,
# Skill invocations) inherits it on first try. Without this the bootstrap
# knows VADE_CLOUD_STATE_DIR and the snapshot user bindir during its own
# run, but they evaporate after exit — leaving CLAUDE.md fallbacks
# (which assume $HOME == cwd) and `command -v op` to fail in fresh shells.
# vade-runtime#83.
merge_coo_settings_paths() {
  local bindir
  bindir="$(_snapshot_user_bindir)"
  _write_claude_settings_paths "$VADE_CLOUD_STATE_DIR" "$bindir"
}

# Merge COO env vars into ~/.claude/settings.json "env" object. Claude
# Code reads this at process startup, so ${GITHUB_MCP_PAT} etc. in
# .mcp.json substitute correctly. Idempotent.
#
# Also surfaces cloud-sandbox tool paths that Claude Code doesn't pick
# up by default but that scripts/agents regularly need:
#   - NODE_PATH points to the sandbox's global node_modules so
#     `import 'playwright'` etc. resolves from any cwd.
#   - PLAYWRIGHT_BROWSERS_PATH points to the pre-installed browser
#     bundle so Playwright finds chromium without a download.
# Both are only exported when the corresponding filesystem path
# exists, so this is a no-op outside the Claude cloud image.
_write_claude_settings_env() {
  local pat="$1" agentmail="$2" mem0="$3"
  if ! check_cmd node; then
    log "Warning: node missing; skipping ~/.claude/settings.json env merge"
    return 0
  fi
  local settings_dir="${HOME}/.claude"
  local settings_file="$settings_dir/settings.json"
  mkdir -p "$settings_dir"
  [ -f "$settings_file" ] || echo '{}' > "$settings_file"

  local node_path=""
  [ -d "/opt/node22/lib/node_modules" ] && node_path="/opt/node22/lib/node_modules"
  local pw_browsers=""
  [ -d "/opt/pw-browsers" ] && pw_browsers="/opt/pw-browsers"

  GITHUB_MCP_PAT="$pat" AGENTMAIL_API_KEY="$agentmail" MEM0_API_KEY="$mem0" \
  NODE_PATH="$node_path" PLAYWRIGHT_BROWSERS_PATH="$pw_browsers" node -e '
    const fs = require("fs");
    const path = process.argv[1];
    let cfg = {};
    try { cfg = JSON.parse(fs.readFileSync(path, "utf8")) || {}; }
    catch (e) {
      console.error("[vade-setup] " + path + " unparseable; aborting env merge.");
      process.exit(1);
    }
    const merged = Object.assign({}, cfg.env || {});
    if (process.env.GITHUB_MCP_PAT) {
      merged.GITHUB_MCP_PAT = process.env.GITHUB_MCP_PAT;
      merged.GITHUB_TOKEN = process.env.GITHUB_MCP_PAT;
    }
    if (process.env.AGENTMAIL_API_KEY) {
      merged.AGENTMAIL_API_KEY = process.env.AGENTMAIL_API_KEY;
    }
    if (process.env.MEM0_API_KEY) {
      merged.MEM0_API_KEY = process.env.MEM0_API_KEY;
    }
    if (process.env.NODE_PATH) {
      merged.NODE_PATH = process.env.NODE_PATH;
    }
    if (process.env.PLAYWRIGHT_BROWSERS_PATH) {
      merged.PLAYWRIGHT_BROWSERS_PATH = process.env.PLAYWRIGHT_BROWSERS_PATH;
    }
    cfg.env = merged;
    fs.writeFileSync(path, JSON.stringify(cfg, null, 2) + "\n");
  ' "$settings_file"
  chmod 600 "$settings_file"
  log "  merged COO env vars into $settings_file"
}

# Persist non-secret path state into the same settings.json env block.
# Split from _write_claude_settings_env because it has no PAT validation
# dependency — it can run any time after _snapshot_user_bindir is
# resolvable, including a re-run on cached-PAT skip path. Idempotent.
#
# - VADE_CLOUD_STATE_DIR: where integrity-check.json, setup-receipt.json,
#   and build.log live. Without this in env, CLAUDE.md's documented
#   ${VADE_CLOUD_STATE_DIR:-$HOME/.vade-cloud-state} fallback resolves
#   to /root/.vade-cloud-state on the cloud harness (HOME=/root) — wrong
#   tree. vade-runtime#83.
# - PATH: prepend the snapshot user bindir so `op`, `gh` (when installed
#   here), and any other ensure_*_cli tooling resolve in shells the
#   harness spawns after bootstrap exits. ensure_op_cli prepends to its
#   own shell only; settings.json env is the durable surface.
#
#   Critical: Claude Code does NOT shell-expand env values from
#   settings.json — it passes them as-is to subprocesses. So we must
#   write the *literal expanded* PATH at bootstrap time, not a
#   "${PATH}" placeholder. The first cut of vade-runtime#83 wrote
#   the literal string "/home/user/.local/bin:${PATH}" and broke fresh
#   sessions (ls/which/bash all "command not found" because ${PATH}
#   was treated as a directory name). This pass captures the actual
#   bootstrap-shell PATH and serializes it.
_write_claude_settings_paths() {
  local cloud_state_dir="$1" bindir="$2"
  if ! check_cmd node; then
    log "Warning: node missing; skipping ~/.claude/settings.json paths merge"
    return 0
  fi
  local settings_dir="${HOME}/.claude"
  local settings_file="$settings_dir/settings.json"
  mkdir -p "$settings_dir"
  [ -f "$settings_file" ] || echo '{}' > "$settings_file"

  # Capture the live PATH for the node child to embed verbatim. Strip
  # any pre-existing bindir prefix so we don't double-prepend across
  # bootstrap re-runs (e.g., after marker invalidation).
  local live_path="${PATH}"
  case ":${live_path}:" in
    ":${bindir}:"*) live_path="${live_path#${bindir}:}" ;;
    *":${bindir}:"*) live_path="${live_path//:${bindir}:/:}" ;;
    *":${bindir}") live_path="${live_path%:${bindir}}" ;;
  esac

  VADE_CLOUD_STATE_DIR="$cloud_state_dir" VADE_BINDIR="$bindir" \
  VADE_LIVE_PATH="$live_path" node -e '
    const fs = require("fs");
    const path = process.argv[1];
    let cfg = {};
    try { cfg = JSON.parse(fs.readFileSync(path, "utf8")) || {}; }
    catch (e) {
      console.error("[vade-setup] " + path + " unparseable; aborting paths merge.");
      process.exit(1);
    }
    const merged = Object.assign({}, cfg.env || {});
    if (process.env.VADE_CLOUD_STATE_DIR) {
      merged.VADE_CLOUD_STATE_DIR = process.env.VADE_CLOUD_STATE_DIR;
    }
    if (process.env.VADE_BINDIR && process.env.VADE_LIVE_PATH !== undefined) {
      // Always rewrite from a known-good base (the captured shell PATH
      // with our bindir stripped) — never inherit a prior settings.json
      // PATH value, because that value may itself be the broken
      // "${PATH}"-literal output of a previous bootstrap run.
      const bindir = process.env.VADE_BINDIR;
      const live = process.env.VADE_LIVE_PATH;
      merged.PATH = live ? bindir + ":" + live : bindir;
    }
    cfg.env = merged;
    fs.writeFileSync(path, JSON.stringify(cfg, null, 2) + "\n");
  ' "$settings_file"
  chmod 600 "$settings_file"
  log "  merged COO path vars into $settings_file"
}

# Ensure openssh-client is present (provides ssh-keygen + ssh-keyscan).
# Returns 0 if available (or successfully installed), 1 otherwise.
# Absence is tolerated by install_coo_ssh_keys (fingerprint check is
# skipped with a warning) — we don't want a minimal base image to
# block identity provisioning.
ensure_openssh_client() {
  if check_cmd ssh-keygen; then
    return 0
  fi
  if ! check_cmd apt-get; then
    log "openssh-client missing and apt-get unavailable; fingerprint check will be skipped"
    return 1
  fi
  log "Installing openssh-client (needed for ssh-keygen fingerprint validation)"
  if sudo -n true 2>/dev/null; then
    sudo apt-get update -qq >/dev/null 2>&1 || true
    sudo apt-get install -y --no-install-recommends openssh-client >/dev/null 2>&1
  else
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y --no-install-recommends openssh-client >/dev/null 2>&1
  fi
  if check_cmd ssh-keygen; then
    log "openssh-client installed"
    return 0
  fi
  log "openssh-client install failed (no sudo or apt denied); fingerprint check will be skipped"
  return 1
}

# Compute ssh-key fingerprint from a pubkey file. Returns empty on
# failure. Wraps the pipeline so we can call it without tripping
# pipefail/set -e in the caller.
_fingerprint_of() {
  local pub="$1"
  ssh-keygen -lf "$pub" 2>/dev/null | awk '{print $2}' || true
}

# Install COO SSH keys from 1Password into ~/.ssh/. Validates
# fingerprints against expected values when ssh-keygen is available;
# logs a warning and continues when it is not (see ensure_openssh_client).
install_coo_ssh_keys() {
  local ssh_dir="${HOME}/.ssh"
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  log "Installing COO SSH keys into $ssh_dir"

  _op_to_file "op://COO/vade-coo-auth/private key" "$ssh_dir/vade-coo-auth"     0600 || return 1
  _op_to_file "op://COO/vade-coo-auth/public key"  "$ssh_dir/vade-coo-auth.pub" 0644 || return 1
  _op_to_file "op://COO/vade-coo-sign/private key" "$ssh_dir/vade-coo-sign"     0600 || return 1
  _op_to_file "op://COO/vade-coo-sign/public key"  "$ssh_dir/vade-coo-sign.pub" 0644 || return 1

  if ensure_openssh_client; then
    local fp_auth fp_sign
    fp_auth="$(_fingerprint_of "$ssh_dir/vade-coo-auth.pub")"
    fp_sign="$(_fingerprint_of "$ssh_dir/vade-coo-sign.pub")"
    if [ "$fp_auth" != "$COO_AUTH_FP_EXPECTED" ]; then
      log "FATAL: auth key fingerprint mismatch (got '${fp_auth:-empty}', expected $COO_AUTH_FP_EXPECTED)"
      return 1
    fi
    if [ "$fp_sign" != "$COO_SIGN_FP_EXPECTED" ]; then
      log "FATAL: signing key fingerprint mismatch (got '${fp_sign:-empty}', expected $COO_SIGN_FP_EXPECTED)"
      return 1
    fi
    log "SSH key fingerprints validated"
  else
    log "WARNING: skipping SSH key fingerprint validation (ssh-keygen unavailable)"
  fi

  local allowed="$ssh_dir/allowed_signers"
  {
    echo "coo@vade-app.dev $(cat "$ssh_dir/vade-coo-auth.pub")"
    echo "coo@vade-app.dev $(cat "$ssh_dir/vade-coo-sign.pub")"
  } > "$allowed"
  chmod 644 "$allowed"
  log "Wrote $allowed"

  if check_cmd ssh-keyscan && ! grep -q '^github.com ' "$ssh_dir/known_hosts" 2>/dev/null; then
    local scan
    # Capture stdout separately so an empty result (e.g. port 22 blocked
    # in the Claude cloud sandbox) doesn't silently touch known_hosts
    # and then lie about success.
    scan="$(ssh-keyscan -T 5 -t rsa,ecdsa,ed25519 github.com 2>/dev/null || true)"
    if [ -n "$scan" ]; then
      printf '%s\n' "$scan" >> "$ssh_dir/known_hosts"
      chmod 644 "$ssh_dir/known_hosts"
      log "Added github.com to $ssh_dir/known_hosts"
    else
      log "WARNING: ssh-keyscan github.com returned nothing (port 22 blocked?); SSH git ops will fail in this environment"
    fi
  fi
}

_op_to_file() {
  local ref="$1" path="$2" mode="$3"
  local content
  # 5 attempts (sleeps 1+2+4+8 = 15s of tolerance) absorbs 1Password
  # service-account cold-start latency on first `op read` of a fresh
  # container. Observed on run-2026-04-22T091701: first bootstrap
  # attempt FAILED at install_coo_ssh_keys; second attempt
  # (`VADE_FORCE_COO_BOOTSTRAP=1`) succeeded after 2 retries on the
  # same ref, suggesting 3 attempts was inside the cold-start window
  # but 5 clears it comfortably.
  if ! content="$(retry 5 op read "$ref")"; then
    log "Failed to read $ref after retries"
    return 1
  fi
  # Empty content from a rc=0 `op read` indicates a 1Password API
  # soft-fail that didn't set an exit code — fail loudly rather than
  # writing a bare-newline file that trips the fingerprint check
  # downstream with a confusing error.
  if [ -z "$content" ]; then
    log "Failed to read $ref: empty content (op read returned rc=0 with no output)"
    return 1
  fi
  (
    umask 077
    printf '%s\n' "$content" > "$path"
  )
  chmod "$mode" "$path"
  log "  wrote $path ($mode)"
}

# Write gitconfig with COO identity + SSH signing + auth-key push.
# Target path is overridable via VADE_COO_GITCONFIG so local-setup.sh can
# route Claude's git through ~/.vade/gitconfig-coo (via GIT_CONFIG_GLOBAL)
# without touching the user's personal ~/.gitconfig.
#
# Signing posture is platform-dependent (MEMO 2026-04-23-04).
# The Claude Code cloud harness sets `gpg.ssh.program=/tmp/code-sign`, a
# wrapper that intercepts `ssh-keygen -Y sign` and substitutes a
# harness-managed key for the one user.signingkey names. Signed output
# produced in cloud is therefore bound to a key that is not on any
# GitHub account and can never pass verification (observed: local key
# SHA256:pZeA8xyc…3nA; signer in signature SHA256:32dP45eS…2wc).
# We detect the harness by the presence of the wrapper at /tmp/code-sign
# OR CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE being set, and turn
# commit.gpgsign/tag.gpgsign off there. Keys, allowed-signers file, and
# core.sshCommand stay set on both platforms so Mac sessions still sign
# normally and SSH auth works on both.
_coo_signing_is_intercepted() {
  [ -x /tmp/code-sign ] || [ -n "${CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE:-}" ]
}

write_coo_gitconfig() {
  local gc="${VADE_COO_GITCONFIG:-${HOME}/.gitconfig}"
  mkdir -p "$(dirname "$gc")"
  git config --file "$gc" user.name "COO"
  git config --file "$gc" user.email "coo@vade-app.dev"
  git config --file "$gc" gpg.format ssh
  git config --file "$gc" user.signingkey "${HOME}/.ssh/vade-coo-sign.pub"
  if _coo_signing_is_intercepted; then
    git config --file "$gc" commit.gpgsign false
    git config --file "$gc" tag.gpgsign false
    log "Configured $gc (user=COO, signing=OFF — cloud harness detected; MEMO 2026-04-23-04)"
  else
    git config --file "$gc" commit.gpgsign true
    git config --file "$gc" tag.gpgsign true
    log "Configured $gc (user=COO, signing=ssh via vade-coo-sign.pub)"
  fi
  git config --file "$gc" gpg.ssh.allowedSignersFile "${HOME}/.ssh/allowed_signers"
  git config --file "$gc" core.sshCommand "ssh -i ${HOME}/.ssh/vade-coo-auth -o IdentitiesOnly=yes -o UserKnownHostsFile=${HOME}/.ssh/known_hosts"
}

# Install the vade-coo git shim at the snapshot-persistent bindir,
# making `git push` route through git-push-with-fallback.sh by default
# (vade-runtime#67 adoption-as-default — the wrapper has been merged
# since #74, but no path made it the default until this shim).
#
# The shim is a symlink to scripts/git-shim.sh in this repo. Removing
# the symlink restores the system git. Set VADE_DISABLE_GIT_SHIM=1 in
# the bootstrap env to skip installation entirely (useful for debug
# sessions where intercepting git push is undesirable).
#
# Idempotent: if the symlink already points to the right source, no-op.
# Fail-soft: refuses to clobber a non-symlink at the install path.
install_coo_git_shim() {
  if [ "${VADE_DISABLE_GIT_SHIM:-0}" = "1" ]; then
    log "git shim install: skipped (VADE_DISABLE_GIT_SHIM=1)"
    return 0
  fi

  local bindir shim_src wrapper shim_dst current_target
  bindir="$(_snapshot_user_bindir)"
  shim_src="$SCRIPT_DIR/git-shim.sh"
  wrapper="$SCRIPT_DIR/git-push-with-fallback.sh"

  if [ ! -x "$shim_src" ]; then
    log_err "git shim install: source not executable at $shim_src; skipping"
    return 1
  fi
  if [ ! -x "$wrapper" ]; then
    log_err "git shim install: wrapper missing at $wrapper; shim would no-op, skipping"
    return 1
  fi

  mkdir -p "$bindir"
  shim_dst="$bindir/git"

  if [ -e "$shim_dst" ] && [ ! -L "$shim_dst" ]; then
    log_err "git shim install: $shim_dst exists and is not a symlink; refusing to clobber"
    log_err "  remove it manually if you want the shim, or set VADE_DISABLE_GIT_SHIM=1"
    return 1
  fi

  if [ -L "$shim_dst" ]; then
    current_target="$(readlink -- "$shim_dst" 2>/dev/null || true)"
    if [ "$current_target" = "$shim_src" ]; then
      log "git shim install: already current at $shim_dst → $shim_src"
      return 0
    fi
  fi

  ln -sfn -- "$shim_src" "$shim_dst"
  log "git shim installed at $shim_dst → $shim_src (intercepts \`git push\`; bypass with VADE_GIT_SHIM_BYPASS=1)"
}

validate_coo_identity() {
  if [ -z "${GITHUB_MCP_PAT:-}" ]; then
    log "Skipping GitHub PAT validation (GITHUB_MCP_PAT unset; degraded bootstrap)"
    return 0
  fi
  local body login
  if ! body="$(retry 3 curl -sfH "Authorization: Bearer ${GITHUB_MCP_PAT}" https://api.github.com/user)"; then
    log "FATAL: GitHub /user lookup failed after retries; cannot confirm identity"
    return 1
  fi
  # GitHub's JSON is indented with spaces around the colon ("login": "...").
  # Tolerate optional whitespace so this doesn't silently fail.
  login="$(printf '%s' "$body" | grep -oE '"login"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/')"
  if [ "$login" != "vade-coo" ]; then
    log "FATAL: GitHub PAT validates as '${login:-unknown}', expected 'vade-coo'"
    return 1
  fi
  log "GitHub PAT valid for: $login"
}

# Quiet variant for the marker-shortcut precondition (#72): probes the
# already-cached $GITHUB_MCP_PAT and returns 0 only when GitHub
# confirms login=vade-coo. No retries (the marker shortcut is a fast
# path; if the network is down, fall through to the full bootstrap
# which has its own retry budget). No log output on the happy path —
# only on fail-and-fall-through, so the operator sees why the marker
# was bypassed. Single curl, hard 5s timeout — keeps the SessionStart
# happy path within the existing budget envelope.
_cached_pat_still_valid() {
  [ -n "${GITHUB_MCP_PAT:-}" ] || return 1
  local body login
  body="$(curl -sfH "Authorization: Bearer ${GITHUB_MCP_PAT}" --max-time 5 \
                  https://api.github.com/user 2>/dev/null)" || return 1
  login="$(printf '%s' "$body" | grep -oE '"login"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/')"
  [ "$login" = "vade-coo" ]
}

summarize_coo_identity() {
  local mode="active"
  [ -z "${GITHUB_MCP_PAT:-}" ] && mode="degraded (GITHUB_MCP_PAT unset)"
  log "COO identity $mode"
  if check_cmd ssh-keygen; then
    log "  auth  $(_fingerprint_of "${HOME}/.ssh/vade-coo-auth.pub" 2>/dev/null || echo unknown)"
    log "  sign  $(_fingerprint_of "${HOME}/.ssh/vade-coo-sign.pub" 2>/dev/null || echo unknown)"
  else
    log "  auth  (ssh-keygen unavailable; fingerprint not shown)"
    log "  sign  (ssh-keygen unavailable; fingerprint not shown)"
  fi
  log "  github pat:    $([ -n "${GITHUB_MCP_PAT:-}" ]  && echo present || echo MISSING)"
  log "  agentmail key: $([ -n "${AGENTMAIL_API_KEY:-}" ] && echo present || echo MISSING)"
}
