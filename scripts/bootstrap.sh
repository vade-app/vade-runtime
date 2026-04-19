#!/usr/bin/env bash
# First-run setup for the VADE devcontainer.
# Idempotent: safe to run multiple times.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

log "VADE devcontainer first-run setup"

ensure_dirs

install_deps /workspace

print_versions

log "Done. Library at $HOME/.vade/library/"
