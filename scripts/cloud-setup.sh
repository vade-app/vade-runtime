#!/usr/bin/env bash
# Claude Code web cloud environment setup.
# Runs once at snapshot build (cached for ~7 days). Subsequent
# session resumes restore the cached snapshot — this script does
# not re-execute on resume.
#
# Entry point: paste this into the cloud env "Setup script" field:
#   #!/bin/bash
#   set -e
#   bash /home/user/vade-runtime/scripts/cloud-setup.sh
#
# The harness clones vade-core, vade-runtime, and vade-coo-memory into
# /home/user/ before this runs, so we just point at /home/user/vade-runtime.
set -euo pipefail

source /home/user/vade-runtime/scripts/lib/common.sh

log "Cloud environment setup starting"
log "Baseline: node=$(node --version 2>/dev/null || echo 'missing') npm=$(npm --version 2>/dev/null || echo 'missing')"

ensure_dirs
sync_claude_config /home/user/vade-runtime/.claude

# Workspace deps (npm install vade-core, install tsx) are opt-in:
# nothing in the SessionStart hook pipeline imports from node_modules,
# and MCP runs remote (mcp.vade-app.dev). Contributors who want the
# full local toolchain set VADE_BOOT_INSTALL=1.
if [ "${VADE_BOOT_INSTALL:-0}" = "1" ]; then
  ensure_tsx
  install_deps /home/user/vade-core
fi

print_versions

# COO identity bootstrap runs only when OP_SERVICE_ACCOUNT_TOKEN is set
# in the cloud environment config. Non-fatal on failure — the base VADE
# env should still come up even if 1Password is unreachable.
# See vade-coo-memory/coo/cloud-env-bootstrap.md for the contract.
# Anthropic cloud envs may scope custom env vars to the session process
# only; the SessionStart hook in .claude/settings.json picks up the
# slack in that case.
if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  bash /home/user/vade-runtime/scripts/coo-bootstrap.sh || \
    log "Warning: coo-bootstrap failed; continuing without COO identity."
else
  log "OP_SERVICE_ACCOUNT_TOKEN not visible at setup time; SessionStart hook will run coo-bootstrap."
fi

log "Done."
