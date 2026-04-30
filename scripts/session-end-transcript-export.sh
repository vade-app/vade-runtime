#!/usr/bin/env bash
# Bash wrapper invoked by the SessionEnd-hook chain (via vade-hooks/dispatch.sh).
# Sources ~/.vade/coo-env so R2_TRANSCRIPTS_* and TRANSCRIPTS_AGE_IDENTITY
# are populated, then runs the Python implementation.
#
# Detach discipline (vade-runtime#NNN, 2026-04-30):
# Under CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 (PR #177 / commit 9f706d7,
# 2026-04-29 03:23 UTC) the harness kills the SessionEnd hook process
# group before the Python export can finish — caught a 48-hour outage
# (R2 has zero objects from 2026-04-29 onward; eight parallel COO
# play-afternoon sessions of 2026-04-29 lost permanently). Foreground
# `exec` did not survive the kill.
#
# Fix: fork the Python via `setsid -f` into a new process session so
# the wrapper can return 0 immediately and the export survives the
# harness teardown. Output goes to a per-invocation log under
# ${HOME}/.vade/transcript-export-logs/ for debugging. The Python
# script's own contract — always exit 0, drop <id>.export-error.txt
# on internal failure — is preserved.
#
# The fail-open contract holds: env-sourcing failure is non-fatal;
# the Python script handles missing R2/age creds by writing
# export-error.txt rather than raising.
#
# vade-app/vade-agent-logs#64 Batch 2; detach fix vade-runtime#NNN.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source coo-env if present (provides R2 + age secrets). Fail-open: if
# the file is missing, the Python script sees empty env vars and
# degrades to writing export-error.txt (per design — never blocks).
if [ -f "${HOME}/.vade/coo-env" ]; then
  # shellcheck disable=SC1090,SC1091
  . "${HOME}/.vade/coo-env" 2>/dev/null || true
fi

# Per-invocation log directory; created lazily so dry-run callers
# don't litter $HOME on first import.
LOG_DIR="${HOME}/.vade/transcript-export-logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true

# Timestamped log filename so concurrent invocations don't collide and
# so post-hoc debugging is easy. Includes wrapper PID for cross-ref
# with /proc/<pid> when the process is still alive.
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/${TS}-$$.log"

# Fork the Python child into a new session/PG so it survives the
# harness killing the SessionEnd hook process group. setsid -f
# (fork) is the load-bearing flag here — `nohup ... &; disown`
# alone wasn't enough under agent-teams (the harness kills by PG,
# not by signaling the wrapper). stdin closed; stdout/stderr to log.
setsid -f "$SCRIPT_DIR/session-end-transcript-export.py" "$@" \
  </dev/null >"$LOG_FILE" 2>&1

# Wrapper returns 0 immediately. The detached child continues in
# its own session and writes meta.json + uploads to R2 on its own
# clock, independent of how the harness handles this hook's exit.
exit 0
