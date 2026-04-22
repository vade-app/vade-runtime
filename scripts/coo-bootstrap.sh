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

if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  log "coo-bootstrap: OP_SERVICE_ACCOUNT_TOKEN unset; skipping COO identity setup."
  exit 0
fi

# Defense in depth behind the SessionStart matcher: secrets don't
# rotate within a container's lifetime, and every artifact this
# script writes (SSH keys, gitconfig, env file, settings.json env
# block) is durable across resumes. Skip the whole pipeline if it
# already ran in this container. Escape hatch:
# VADE_FORCE_COO_BOOTSTRAP=1.
COO_ENV_FILE="${HOME}/.vade/coo-env"
COO_BOOT_MARKER="${HOME}/.vade/.coo-bootstrap-done"
if [ "${VADE_FORCE_COO_BOOTSTRAP:-0}" != "1" ] \
   && [ -f "$COO_ENV_FILE" ] && [ -f "$COO_BOOT_MARKER" ]; then
  log "coo-bootstrap: already complete this container; skipping."
  exit 0
fi

log "coo-bootstrap: starting"

ensure_op_cli

# Verify the service-account token before attempting any reads.
if ! op whoami >/dev/null 2>&1; then
  log "FATAL: op whoami failed. Check OP_SERVICE_ACCOUNT_TOKEN and vault access."
  exit 1
fi
log "1Password service account authenticated: $(op whoami 2>/dev/null | head -1)"

install_coo_ssh_keys
fetch_coo_secrets
write_coo_gitconfig
validate_coo_identity
summarize_coo_identity

mkdir -p "$(dirname "$COO_BOOT_MARKER")"
touch "$COO_BOOT_MARKER"

log "coo-bootstrap: complete"
