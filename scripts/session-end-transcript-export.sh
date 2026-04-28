#!/usr/bin/env bash
# Bash wrapper invoked by the Stop-hook chain (via vade-hooks/dispatch.sh).
# Sources ~/.vade/coo-env so R2_TRANSCRIPTS_* and TRANSCRIPTS_AGE_IDENTITY
# are populated, then exec's the Python implementation.
#
# The Python script never raises to its own caller — it always exits 0
# and drops <sessionId>.export-error.txt on any internal failure. This
# wrapper preserves that contract: it does not `set -e`, and runs the
# Python script even if env-sourcing fails.
#
# vade-app/vade-agent-logs#64 Batch 2.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source coo-env if present (provides R2 + age secrets). Fail-open: if
# the file is missing, the Python script sees empty env vars and
# degrades to writing export-error.txt (per design — never blocks).
if [ -f "${HOME}/.vade/coo-env" ]; then
  # shellcheck disable=SC1090,SC1091
  . "${HOME}/.vade/coo-env" 2>/dev/null || true
fi

exec "$SCRIPT_DIR/session-end-transcript-export.py" "$@"
