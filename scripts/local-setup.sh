#!/usr/bin/env bash
# Local (macOS) equivalent of cloud-setup.sh. Runs from a user-scope
# SessionStart hook when Claude Code is launched from any repo under
# ~/GitHub/vade-app/. Delegates to coo-bootstrap.sh for the full COO
# identity pipeline (SSH keys, gitconfig, MCP env vars, receipt, logs) —
# same code path as cloud, with two env-var redirects so the artifacts
# land in ~/.vade/local-state/ and ~/.vade/gitconfig-coo rather than the
# cloud-specific /home/user/ paths and the user's personal ~/.gitconfig.
#
# Expects OP_SERVICE_ACCOUNT_TOKEN in the process env. The dotfiles
# claude() wrapper is the intended provisioner:
# zsh/.config/zsh/functions.zsh `op read`s the COO vault's sandbox SA
# token into OP_SERVICE_ACCOUNT_TOKEN only when $PWD is under
# ~/GitHub/vade-app/, so normal shells and non-vade projects stay
# untouched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export VADE_CLOUD_STATE_DIR="${VADE_CLOUD_STATE_DIR:-${HOME}/.vade/local-state}"
export VADE_COO_GITCONFIG="${VADE_COO_GITCONFIG:-${HOME}/.vade/gitconfig-coo}"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

log "Local environment setup starting"
build_log_record START "local-setup: begin (mode=local)"

ensure_dirs

OP_TOKEN_VISIBLE=false
COO_BOOTSTRAP_RAN=false
if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  OP_TOKEN_VISIBLE=true
  build_log_record PROBE "local-setup: OP_SERVICE_ACCOUNT_TOKEN present (len=${#OP_SERVICE_ACCOUNT_TOKEN})"
  if bash "$SCRIPT_DIR/coo-bootstrap.sh"; then
    COO_BOOTSTRAP_RAN=true
    build_log_record OK "local-setup: coo-bootstrap completed"
  else
    build_log_record FAIL "local-setup: coo-bootstrap failed; continuing without COO identity"
    log "Warning: coo-bootstrap failed; continuing without COO identity."
  fi
else
  build_log_record PROBE "local-setup: OP_SERVICE_ACCOUNT_TOKEN unset; skipping"
  log "OP_SERVICE_ACCOUNT_TOKEN unset; skipping COO bootstrap. (Claude launched outside the claude() wrapper?)"
fi

GIT_SHA="$(git -C "$SCRIPT_DIR/.." rev-parse --short HEAD 2>/dev/null || echo unknown)"
build_receipt_write \
  built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  mode=local \
  op_token_visible="$OP_TOKEN_VISIBLE" \
  coo_bootstrap_ran="$COO_BOOTSTRAP_RAN" \
  git_sha="$GIT_SHA"

build_log_record OK "local-setup: complete (op_token=$OP_TOKEN_VISIBLE coo_bootstrap=$COO_BOOTSTRAP_RAN)"
log "Done."
