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
    const required = ["GITHUB_MCP_PAT", "GITHUB_TOKEN", "AGENTMAIL_API_KEY"];
    for (const k of required) { if (!env[k]) process.exit(1); }
    process.exit(0);
  ' "$settings" 2>/dev/null
}
if [ "${VADE_FORCE_COO_BOOTSTRAP:-0}" != "1" ] \
   && [ -f "$COO_ENV_FILE" ] && [ -f "$COO_BOOT_MARKER" ] \
   && _settings_env_complete; then
  log "coo-bootstrap: already complete this container; skipping."
  COO_BOOTSTRAP_STEP="skip-marker-present"
  bootstrap_log_record SKIP "marker present at $COO_BOOT_MARKER"
  trap - EXIT
  exit 0
fi
if [ -f "$COO_BOOT_MARKER" ] && [ "${VADE_FORCE_COO_BOOTSTRAP:-0}" != "1" ]; then
  log "coo-bootstrap: marker present but settings.json env incomplete; re-running"
  bootstrap_log_record START "marker stale (settings.json env missing keys); forcing re-run"
fi

log "coo-bootstrap: starting"
bootstrap_log_record START "VADE_FORCE_COO_BOOTSTRAP=${VADE_FORCE_COO_BOOTSTRAP:-0}"

COO_BOOTSTRAP_STEP="ensure_op_cli"
ensure_op_cli

# Verify the service-account token before attempting any reads. Retry
# to absorb transient 1Password API errors (503s).
COO_BOOTSTRAP_STEP="op_whoami"
if ! retry 3 op whoami >/dev/null; then
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

COO_BOOTSTRAP_STEP="validate_coo_identity"
validate_coo_identity

COO_BOOTSTRAP_STEP="summarize_coo_identity"
summarize_coo_identity

mkdir -p "$(dirname "$COO_BOOT_MARKER")"
touch "$COO_BOOT_MARKER"

COO_BOOTSTRAP_STEP="complete"
log "coo-bootstrap: complete"
