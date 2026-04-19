#!/usr/bin/env bash
# Install the vade SessionStart hook into ~/.claude/settings.json.
#
# The hook runs scripts/discussions-digest.sh on every Claude Code
# session start, printing a short digest of new org discussions.
#
# Idempotent: does not add a duplicate entry if already installed.
# Safe no-op if node is unavailable or settings.json is unparseable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

if ! check_cmd node; then
  log "node missing; cannot install agent hooks."
  exit 0
fi

SETTINGS_DIR="$HOME/.claude"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"
mkdir -p "$SETTINGS_DIR"

DIGEST_CMD="bash $SCRIPT_DIR/discussions-digest.sh"

node -e '
const fs = require("fs");
const path = process.argv[1];
const cmd = process.argv[2];

let cfg = {};
if (fs.existsSync(path)) {
  try {
    cfg = JSON.parse(fs.readFileSync(path, "utf8"));
  } catch (e) {
    console.error("[vade-setup] " + path + " exists but is unparseable; aborting hook install. Fix manually.");
    process.exit(1);
  }
}

cfg.hooks = cfg.hooks || {};
cfg.hooks.SessionStart = cfg.hooks.SessionStart || [];

const already = cfg.hooks.SessionStart.some(entry =>
  entry && Array.isArray(entry.hooks) &&
  entry.hooks.some(h => h && h.command === cmd)
);

if (already) {
  console.log("[vade-setup] SessionStart hook already installed.");
  process.exit(0);
}

cfg.hooks.SessionStart.push({
  hooks: [{ type: "command", command: cmd }],
});

fs.writeFileSync(path, JSON.stringify(cfg, null, 2) + "\n");
console.log("[vade-setup] Installed SessionStart hook → " + cmd);
' "$SETTINGS_FILE" "$DIGEST_CMD"
