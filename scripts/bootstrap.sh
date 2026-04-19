#!/usr/bin/env bash
# First-run setup for the VADE devcontainer.
# Idempotent: safe to run multiple times.
set -euo pipefail

echo "[bootstrap] VADE devcontainer first-run setup"

# Ensure the library directory structure exists. The volume mount
# creates the root as a mount point; we create subdirs on first run.
mkdir -p "$HOME/.vade/library/canvases" "$HOME/.vade/library/entities" 2>/dev/null || \
  echo "[bootstrap] Warning: could not create $HOME/.vade subdirs. Check volume permissions."

# If we're inside a vade-core checkout, install npm deps so the
# dev loop is ready immediately.
if [ -f "/workspace/package.json" ]; then
  echo "[bootstrap] Installing npm dependencies..."
  cd /workspace
  npm install --no-audit --no-fund
fi

# Verify the tools we expect are on PATH.
echo "[bootstrap] Tool versions:"
node --version
npm --version
claude --version 2>/dev/null || echo "  claude CLI: not logged in (run 'claude login' after first start)"
tsx --version 2>/dev/null || npx tsx --version

echo "[bootstrap] Done. Library at $HOME/.vade/library/"
