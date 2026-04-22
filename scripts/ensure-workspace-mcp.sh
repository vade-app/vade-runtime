#!/usr/bin/env bash
# Ensure /home/user/.mcp.json symlinks to the workspace MCP config so
# Claude Code picks up mem0 + agentmail MCPs when booting from its
# default cwd (/home/user/). Cheap idempotent no-op when already
# linked; logs one line when it has to (re)create the symlink.
#
# Wired into SessionStart:startup so the current container gets the
# link without waiting for a snapshot rebuild. Also called from
# cloud-setup.sh so the snapshot itself bakes the link in.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ensure_workspace_mcp_config
