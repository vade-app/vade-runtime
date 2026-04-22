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
build_log_record START "cloud-setup: begin"
log "Baseline: node=$(node --version 2>/dev/null || echo 'missing') npm=$(npm --version 2>/dev/null || echo 'missing')"

ensure_dirs
sync_claude_config /home/user/vade-runtime/.claude
ensure_workspace_mcp_config
ensure_workspace_identity_link

# Validate the synced settings.json actually parses as JSON and has a
# populated SessionStart:startup hook chain. File-exists alone would
# pass on a truncated or corrupt file. Node is guaranteed present on
# the cloud image; fall back to file-exists only if node is missing.
SETTINGS_SYNC_OK=false
if [ -f "$HOME/.claude/settings.json" ]; then
  if check_cmd node; then
    if node -e '
      const fs = require("fs");
      const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const chains = (cfg.hooks && cfg.hooks.SessionStart) || [];
      for (const c of chains) {
        if (c.matcher === "startup" && Array.isArray(c.hooks) && c.hooks.length > 0) process.exit(0);
      }
      process.exit(1);
    ' "$HOME/.claude/settings.json" 2>/dev/null; then
      SETTINGS_SYNC_OK=true
    fi
  else
    SETTINGS_SYNC_OK=true
  fi
fi

WORKSPACE_MCP_SYMLINKED=false
[ -L /home/user/.mcp.json ] && \
  [ "$(readlink -f /home/user/.mcp.json 2>/dev/null)" = "$(readlink -f /home/user/vade-runtime/.mcp.json 2>/dev/null)" ] && \
  WORKSPACE_MCP_SYMLINKED=true

IDENTITY_LINK_OK=false
[ -L /home/user/CLAUDE.md ] && \
  [ "$(readlink -f /home/user/CLAUDE.md 2>/dev/null)" = "$(readlink -f /home/user/vade-coo-memory/CLAUDE.md 2>/dev/null)" ] && \
  IDENTITY_LINK_OK=true

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
#
# Probe: record token visibility and settings.json state so the next
# session's identity-digest can tell us whether setup-script time is
# a viable bootstrap site (structurally superior to the hook because
# MCP servers pick up env at Claude Code startup, not post-hook).
OP_TOKEN_VISIBLE=false
COO_BOOTSTRAP_RAN=false
if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  OP_TOKEN_VISIBLE=true
  build_log_record PROBE "cloud-setup: OP_SERVICE_ACCOUNT_TOKEN visible at setup time (len=${#OP_SERVICE_ACCOUNT_TOKEN})"
  if bash /home/user/vade-runtime/scripts/coo-bootstrap.sh; then
    COO_BOOTSTRAP_RAN=true
    build_log_record OK "cloud-setup: coo-bootstrap completed"
  else
    build_log_record FAIL "cloud-setup: coo-bootstrap failed; continuing without COO identity"
    log "Warning: coo-bootstrap failed; continuing without COO identity."
  fi
else
  build_log_record PROBE "cloud-setup: OP_SERVICE_ACCOUNT_TOKEN unset at setup time; hook fallback required"
  log "OP_SERVICE_ACCOUNT_TOKEN not visible at setup time; SessionStart hook will run coo-bootstrap."
fi

# Durable receipt so sessions can diagnose build-time state without
# parsing logs. coo-identity-digest surfaces this in the SessionStart
# digest block.
GIT_SHA="$(git -C /home/user/vade-runtime rev-parse --short HEAD 2>/dev/null || echo unknown)"
build_receipt_write \
  built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  op_token_visible="$OP_TOKEN_VISIBLE" \
  coo_bootstrap_ran="$COO_BOOTSTRAP_RAN" \
  workspace_mcp_symlinked="$WORKSPACE_MCP_SYMLINKED" \
  identity_link_ok="$IDENTITY_LINK_OK" \
  settings_sync_ok="$SETTINGS_SYNC_OK" \
  git_sha="$GIT_SHA"

build_log_record OK "cloud-setup: complete (op_token=$OP_TOKEN_VISIBLE coo_bootstrap=$COO_BOOTSTRAP_RAN mcp_link=$WORKSPACE_MCP_SYMLINKED id_link=$IDENTITY_LINK_OK)"
log "Done."
