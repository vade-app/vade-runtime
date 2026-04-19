#!/usr/bin/env bash
# Shared functions for VADE environment setup scripts.
# Sourced by bootstrap.sh (devcontainer) and cloud-setup.sh (web).

log() { echo "[vade-setup] $*"; }

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

print_versions() {
  log "Tool versions:"
  log "  node: $(node --version 2>/dev/null || echo 'not found')"
  log "  npm:  $(npm --version 2>/dev/null || echo 'not found')"
  log "  git:  $(git --version 2>/dev/null || echo 'not found')"
  log "  tsx:  $(tsx --version 2>/dev/null | head -1 || echo 'not found')"
  log "  claude: $(claude --version 2>/dev/null || echo 'not available')"
}
