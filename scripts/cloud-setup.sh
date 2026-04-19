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
  git clone https://github.com/vade-app/vade-core.git "$REPOS_ROOT/vade-core"
fi

install_deps "$REPOS_ROOT/vade-core"

print_versions

log "Done. vade-core at $REPOS_ROOT/vade-core, library at $HOME/.vade/library/"
