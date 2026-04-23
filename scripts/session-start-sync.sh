#!/usr/bin/env bash
# Defensive re-sync on every SessionStart.
#
# Cloud snapshots go stale: the committed repo advances, but the
# baked-in ~/.claude/settings.json and workspace-scope symlinks reflect
# whatever was in vade-runtime at build time. This script closes that
# gap by re-running the idempotent pieces of cloud-setup.sh that don't
# need 1Password access:
#
#   1. sync_claude_config  — mirror vade-runtime/.claude into ~/.claude,
#      preserving the env block populated by coo-bootstrap so MCPs
#      still pick up credentials.
#   2. ensure_workspace_mcp_config — /home/user/.mcp.json symlink.
#   3. ensure_workspace_identity_link — /home/user/CLAUDE.md symlink so
#      the harness memory loader auto-reads vade-coo-memory's identity.
#
# Runs first in the SessionStart:startup hook chain (before
# coo-bootstrap) so all later hooks see the freshest hook list and
# symlinks. The sync itself still runs after MCP resolution, so new
# MCPs from a repo update only become visible from session N+1. That's
# the fundamental Phase-B constraint, not something we can close here.
#
# Safe to re-run any number of times; exits 0 on every path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

boot_log_record session-start-sync start
sync_claude_config "$SCRIPT_DIR/../.claude"
ensure_workspace_mcp_config
ensure_workspace_identity_link
# Bridge /home/user/.local/bin/gh (persistent install target) onto
# /root/.local/bin (already on PATH for Claude's Bash tool) so the
# MEMO 2026-04-23-02 gh-CLI fallback is callable without the agent
# having to rediscover the install path every session.
ensure_gh_symlink_on_path
# Emit integrity-check.json so its snapshot is on disk before the
# digest hook runs (which may surface a one-line summary). Non-fatal.
bash "$SCRIPT_DIR/integrity-check.sh" 2>/dev/null || true
boot_log_record session-start-sync end ok
