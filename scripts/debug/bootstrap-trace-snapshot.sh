#!/usr/bin/env bash
# bootstrap-trace-snapshot.sh
#
# Hybrid filesystem snapshot for the bootstrap trace harness.
# Called from bootstrap-trace-init.sh at every bash invocation entry.
#
#   Usage: bootstrap-trace-snapshot.sh <tag> <trace-dir>
#
# Content snapshot (cp -p) of small mutable state files; metadata snapshot
# (find -printf) of the larger trees. Each snapshot lands in
#   <trace-dir>/snapshots/<timestamp>-<tag>-<pid>/
# Sortable by timestamp prefix. Globally unique without a counter file.
#
# Plan: /root/.claude/plans/let-s-start-with-the-dapper-torvalds.md

set -uo pipefail

TAG="${1:-unknown}"
TRACE_DIR="${2:-${VADE_BOOTSTRAP_TRACE_DIR:-$HOME/.vade/traces}}"

# Sanitize the tag: replace anything that's not alnum/dash/dot/underscore.
SAFE_TAG=$(printf '%s' "$TAG" | tr -c 'A-Za-z0-9._-' '_')

STAMP=$(date -u +%Y%m%dT%H%M%S%6N 2>/dev/null || date -u +%Y%m%dT%H%M%S)
SNAP="$TRACE_DIR/snapshots/${STAMP}-${SAFE_TAG}-$$"

mkdir -p "$SNAP/content" "$SNAP/metadata" 2>/dev/null || exit 0

# --- Content snapshots: small files we want diffable byte-for-byte. ---

# ~/.claude settings (the central object the boot pipeline mutates).
for f in "$HOME/.claude/settings.json" \
         "$HOME/.claude/settings.local.json" \
         "$HOME/.claude/settings.json.env"; do
    if [[ -f "$f" ]]; then
        cp -p "$f" "$SNAP/content/$(basename "$f")" 2>/dev/null
    fi
done

# ~/.vade — boot logs, marker files, sentinel files. Skip our own traces.
if [[ -d "$HOME/.vade" ]]; then
    mkdir -p "$SNAP/content/dot-vade"
    find "$HOME/.vade" -maxdepth 2 -type f -not -path "*/traces/*" \
        -exec cp -p {} "$SNAP/content/dot-vade/" \; 2>/dev/null
fi

# ~/.vade-cloud-state — integrity-check.json + receipts.
if [[ -d "$HOME/.vade-cloud-state" ]]; then
    mkdir -p "$SNAP/content/dot-vade-cloud-state"
    find "$HOME/.vade-cloud-state" -maxdepth 2 -type f \
        -exec cp -p {} "$SNAP/content/dot-vade-cloud-state/" \; 2>/dev/null
fi

# --- Metadata snapshots: path / size / mtime / mode for the larger trees. ---

# All of ~/.claude (excluding what we already content-snapshotted, but
# include anyway — duplication is fine and the diff is cheap).
if [[ -d "$HOME/.claude" ]]; then
    find "$HOME/.claude" -type f -printf '%p\t%s\t%T@\t%m\n' \
        > "$SNAP/metadata/dot-claude.tsv" 2>/dev/null
fi

# /home/user top-level only (depth=1). Captures the repo working trees'
# presence + immediate children without exploding the artifact size.
find /home/user -maxdepth 1 -printf '%p\t%y\t%s\t%T@\t%m\n' \
    > "$SNAP/metadata/home-user.tsv" 2>/dev/null

# Process state at snapshot time — useful for "what was running."
ps -eo pid,ppid,pgid,stat,cmd > "$SNAP/metadata/processes.txt" 2>/dev/null

# Env at snapshot time. Strip anything that obviously contains a secret token
# (defensive — this lands on disk and may end up in a PR if shared).
env | grep -vE '(TOKEN|API_KEY|SECRET|PASSWORD|PAT|CLOUDFLARE_API)=' \
    | sort > "$SNAP/metadata/env.txt" 2>/dev/null

exit 0
