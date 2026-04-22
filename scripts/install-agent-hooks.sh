#!/usr/bin/env bash
# Install the vade hooks into ~/.claude/settings.json.
#
# Hooks installed (event → command):
#   SessionStart → scripts/coo-bootstrap.sh       (no-op unless OP_SERVICE_ACCOUNT_TOKEN set)
#   SessionStart → scripts/discussions-digest.sh
#   SessionStart → scripts/session-lifecycle.sh
#   Stop         → scripts/session-lifecycle.sh --end
#
# Idempotent: does not add duplicate entries if already installed.
# Safe no-op if node is unavailable or settings.json is unparseable.
#
# The coo-bootstrap hook is belt-and-suspenders: cloud-setup.sh also
# calls it at setup time, but Anthropic cloud envs may scope custom
# env vars to the session process only — in that case the hook is the
# only path that sees OP_SERVICE_ACCOUNT_TOKEN.
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

COO_BOOTSTRAP_CMD="bash $SCRIPT_DIR/coo-bootstrap.sh"
DIGEST_CMD="bash $SCRIPT_DIR/discussions-digest.sh"
LIFECYCLE_START_CMD="bash $SCRIPT_DIR/session-lifecycle.sh"
LIFECYCLE_END_CMD="bash $SCRIPT_DIR/session-lifecycle.sh --end"

# Pairs of "event|command" for the node script to install.
# Order matters for SessionStart: coo-bootstrap runs first so digest
# and session-lifecycle see the COO env vars (GITHUB_TOKEN etc.) that
# the bootstrap exports via ~/.vade/coo-env and the settings.json merge.
HOOK_SPEC="$(cat <<EOF
SessionStart|$COO_BOOTSTRAP_CMD
SessionStart|$DIGEST_CMD
SessionStart|$LIFECYCLE_START_CMD
Stop|$LIFECYCLE_END_CMD
EOF
)"

node -e '
const fs = require("fs");
const path = process.argv[1];
const spec = process.argv[2];

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

const entries = spec.split("\n").filter(Boolean).map(line => {
  const [event, ...cmdParts] = line.split("|");
  return { event, command: cmdParts.join("|") };
});

let dirty = false;
for (const { event, command } of entries) {
  cfg.hooks[event] = cfg.hooks[event] || [];
  const already = cfg.hooks[event].some(entry =>
    entry && Array.isArray(entry.hooks) &&
    entry.hooks.some(h => h && h.command === command)
  );
  if (already) {
    console.log("[vade-setup] " + event + " hook already installed → " + command);
    continue;
  }
  cfg.hooks[event].push({ hooks: [{ type: "command", command }] });
  console.log("[vade-setup] Installed " + event + " hook → " + command);
  dirty = true;
}

if (dirty) {
  fs.writeFileSync(path, JSON.stringify(cfg, null, 2) + "\n");
}
' "$SETTINGS_FILE" "$HOOK_SPEC"
