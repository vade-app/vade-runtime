#!/usr/bin/env bash
# Claude Code web cloud environment setup.
# Runs once per session, before Claude Code launches.
#
# Entry point: paste this into the cloud env "Setup script" field:
#   #!/bin/bash
#   git clone --depth 1 https://github.com/vade-app/vade-runtime /tmp/vade-runtime
#   bash /tmp/vade-runtime/scripts/cloud-setup.sh
#
# Or run directly if vade-runtime is already cloned.
#
# Tracks main — acceptable for personal prototype phase.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

log "Cloud environment setup starting"

log "Baseline: node=$(node --version 2>/dev/null || echo 'missing') npm=$(npm --version 2>/dev/null || echo 'missing')"

ensure_dirs
ensure_tsx

REPOS_ROOT="${VADE_REPOS_ROOT:-$HOME/repos}"
mkdir -p "$REPOS_ROOT"

if [ ! -d "$REPOS_ROOT/vade-core" ]; then
  log "Cloning vade-core..."
  git clone --depth 1 https://github.com/vade-app/vade-core.git "$REPOS_ROOT/vade-core"
fi

install_deps "$REPOS_ROOT/vade-core"

ensure_agent_hooks "$SCRIPT_DIR"

# In a cloud sandbox the setup script effectively IS the session start,
# so run the digest inline. The hook also gets installed so any nested
# `claude` invocations get a fresh digest.
# bash "$SCRIPT_DIR/discussions-digest.sh" || true

print_versions

# COO identity bootstrap runs only when OP_SERVICE_ACCOUNT_TOKEN is set
# in the cloud environment config. Non-fatal on failure — the base VADE
# env should still come up even if 1Password is unreachable.
# See vade-coo-memory/coo/cloud-env-bootstrap.md for the contract.
if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  bash "$SCRIPT_DIR/coo-bootstrap.sh" || \
    log "Warning: coo-bootstrap failed; continuing without COO identity."
fi

log "Done. vade-core at $REPOS_ROOT/vade-core, library at $HOME/.vade/library/"
