#!/usr/bin/env bash
# COO identity bootstrap for cloud Claude Code sessions.
#
# Called by cloud-setup.sh when OP_SERVICE_ACCOUNT_TOKEN is present.
# Pulls COO credentials from 1Password (vault "COO") via the op CLI,
# writes SSH keys + gitconfig + env file, validates GitHub identity.
#
# Contract: vade-coo-memory/coo/cloud-env-bootstrap.md.
# Architecture rationale: MEMO 2026-04-22-03 (supersedes -22-01 §2).
#
# Fail modes are loud (exit non-zero) so the caller can decide whether
# to continue the VADE setup without COO identity.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

boot_log_record coo-bootstrap start

# Record every exit path in ~/.vade/coo-bootstrap.log so silent failures
# still leave a trail. The identity-digest hook surfaces the tail of
# this file on each session start.
COO_BOOTSTRAP_STEP="init"
_on_exit() {
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    bootstrap_log_record OK "step=${COO_BOOTSTRAP_STEP} rc=0"
    boot_log_record coo-bootstrap end ok "step=${COO_BOOTSTRAP_STEP}"
  else
    bootstrap_log_record FAIL "step=${COO_BOOTSTRAP_STEP} rc=${rc}"
    boot_log_record coo-bootstrap end fail "step=${COO_BOOTSTRAP_STEP}" "rc=${rc}"
  fi
  return $rc
}
trap _on_exit EXIT

if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  log "coo-bootstrap: OP_SERVICE_ACCOUNT_TOKEN unset; skipping COO identity setup."
  COO_BOOTSTRAP_STEP="skip-no-op-token"
  bootstrap_log_record SKIP "OP_SERVICE_ACCOUNT_TOKEN unset"
  trap - EXIT
  exit 0
fi

# Defense in depth behind the SessionStart matcher: secrets don't
# rotate within a container's lifetime, and every artifact this
# script writes (SSH keys, gitconfig, env file, settings.json env
# block) is durable across resumes. Skip the whole pipeline if it
# already ran in this container. Escape hatch:
# VADE_FORCE_COO_BOOTSTRAP=1.
#
# Also verify the settings.json env block actually contains the keys
# a successful bootstrap would have written. A bare marker is not
# enough: if an earlier bootstrap ran under pre-#18 code it left the
# marker without populating GITHUB_MCP_PAT into ~/.claude/settings.json,
# and the session resume came up with github MCP unauth. If any expected
# key is absent, treat the marker as stale and re-run. run-2026-04-22T073717
# hit exactly this: marker present, settings.json env had only
# AGENTMAIL_API_KEY, GITHUB_MCP_PAT was unset, vade-coo identity dark.
COO_ENV_FILE="${HOME}/.vade/coo-env"
COO_BOOT_MARKER="${HOME}/.vade/.coo-bootstrap-done"
_settings_env_complete() {
  local settings="${HOME}/.claude/settings.json"
  [ -f "$settings" ] || return 1
  check_cmd node || return 0  # node missing: fall back to marker-only trust
  node -e '
    const fs = require("fs");
    let cfg = {};
    try { cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8")) || {}; }
    catch { process.exit(1); }
    const env = cfg.env || {};
    const required = ["GITHUB_MCP_PAT", "GITHUB_TOKEN", "AGENTMAIL_API_KEY", "MEM0_API_KEY",
                      "VADE_CLOUD_STATE_DIR", "PATH"];
    for (const k of required) { if (!env[k]) process.exit(1); }
    process.exit(0);
  ' "$settings" 2>/dev/null
}
if [ "${VADE_FORCE_COO_BOOTSTRAP:-0}" != "1" ] \
   && [ -f "$COO_ENV_FILE" ] && [ -f "$COO_BOOT_MARKER" ] \
   && _settings_env_complete \
   && _cached_pat_still_valid; then
  log "coo-bootstrap: already complete this container; skipping."
  COO_BOOTSTRAP_STEP="skip-marker-present"
  bootstrap_log_record SKIP "marker present at $COO_BOOT_MARKER (cached PAT validated)"
  trap - EXIT
  exit 0
fi
if [ -f "$COO_BOOT_MARKER" ] && [ "${VADE_FORCE_COO_BOOTSTRAP:-0}" != "1" ]; then
  # Marker exists but at least one shortcut precondition failed:
  # settings.json env block is missing a key (pre-#18 bootstrap, see
  # comment above), or the cached PAT no longer authenticates as
  # vade-coo (#72 — revocation/scope-change/expiry between snapshots).
  # Fall through to the full bootstrap to refresh both.
  if [ -f "$COO_ENV_FILE" ] && _settings_env_complete \
     && ! _cached_pat_still_valid; then
    log "coo-bootstrap: marker present but cached GITHUB_MCP_PAT no longer authenticates as vade-coo; re-running"
    bootstrap_log_record START "marker stale (cached PAT failed validation); forcing re-run"
  else
    log "coo-bootstrap: marker present but settings.json env incomplete; re-running"
    bootstrap_log_record START "marker stale (settings.json env missing keys); forcing re-run"
  fi
fi

log "coo-bootstrap: starting"
bootstrap_log_record START "VADE_FORCE_COO_BOOTSTRAP=${VADE_FORCE_COO_BOOTSTRAP:-0}"

COO_BOOTSTRAP_STEP="ensure_op_cli"
ensure_op_cli

# Verify the service-account token before attempting any reads. Retry
# to absorb transient 1Password API errors (503s). 5 attempts
# (~15s tolerance) matches _op_to_file's already-tuned budget
# (lib/common.sh _op_to_file) — same flake mode. #76 propagates the
# proven budget here after run-2026-04-25T182206 exhausted the
# prior 3-attempt budget on a transient api.1password.com hiccup.
COO_BOOTSTRAP_STEP="op_whoami"
if ! retry 5 op whoami >/dev/null; then
  log "FATAL: op whoami failed after retries. Check OP_SERVICE_ACCOUNT_TOKEN and vault access."
  exit 1
fi
log "1Password service account authenticated: $(op whoami 2>/dev/null | head -1)"

COO_BOOTSTRAP_STEP="install_coo_ssh_keys"
install_coo_ssh_keys

COO_BOOTSTRAP_STEP="fetch_coo_secrets"
fetch_coo_secrets

COO_BOOTSTRAP_STEP="write_coo_gitconfig"
write_coo_gitconfig

# Validate BEFORE merging into ~/.claude/settings.json (#66): a
# wrong-identity PAT must never land in the harness's persistent env
# block. fetch_coo_secrets stages secrets in ~/.vade/coo-env and exports
# them to this shell so validate_coo_identity can hit api.github.com;
# only after that succeeds does merge_coo_settings_env write the PAT
# into settings.json. set -e ensures we exit before merge on validate
# failure.
COO_BOOTSTRAP_STEP="validate_coo_identity"
validate_coo_identity

COO_BOOTSTRAP_STEP="merge_coo_settings_env"
merge_coo_settings_env

# Persist non-secret path state (VADE_CLOUD_STATE_DIR + PATH with the
# snapshot user bindir prepended) into ~/.claude/settings.json env so
# fresh shells inherit it on first try. vade-runtime#83.
COO_BOOTSTRAP_STEP="merge_coo_settings_paths"
merge_coo_settings_paths

COO_BOOTSTRAP_STEP="summarize_coo_identity"
summarize_coo_identity

mkdir -p "$(dirname "$COO_BOOT_MARKER")"
touch "$COO_BOOT_MARKER"

COO_BOOTSTRAP_STEP="complete"
log "coo-bootstrap: complete"
