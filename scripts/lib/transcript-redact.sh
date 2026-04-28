#!/usr/bin/env bash
# Bash wrapper around transcript-redact.py for callsite consistency
# with other scripts in scripts/lib (which are predominantly bash).
# The Python engine carries the actual logic.
#
# Usage:
#   transcript-redact.sh < input.jsonl > redacted.jsonl 2> hits.json
#   transcript-redact.sh --input X --output Y --hits Z
#
# Exit codes:
#   0 — redaction completed
#   non-zero — engine crashed; caller should NOT fall back to writing
#              the unredacted file. Drop {sessionId}.export-error.txt
#              instead.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/transcript-redact.py" "$@"
