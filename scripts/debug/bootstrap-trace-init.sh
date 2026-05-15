#!/usr/bin/env bash
# bootstrap-trace-init.sh
#
# Sourced via BASH_ENV by every non-interactive bash invocation in the
# container. Hard no-op unless VADE_BOOTSTRAP_TRACE_MODE=1.
#
# When trace mode is on, installs:
#   1. xtrace (set -x) into a dedicated fd, with rich PS4 prefix → xtrace.log
#   2. inotifywait on ~/.claude, ~/.vade, ~/.vade-cloud-state → file-events.log
#   3. per-bash-invocation snapshot at entry, named after the script
#
# Plan: /root/.claude/plans/let-s-start-with-the-dapper-torvalds.md
# Constraints: no modification of any existing script. Trace is observer only.
# Container UI configuration documented in scripts/debug/README.md.

# Hard no-op when trace mode is off. Works whether sourced or executed.
[[ "${VADE_BOOTSTRAP_TRACE_MODE:-0}" == "1" ]] || return 0 2>/dev/null || exit 0

# Skip self-trace for the snapshot helper to avoid recursive fork-bombs
# (snapshot helper is itself bash; BASH_ENV would re-source us).
case "${0##*/}" in
    bootstrap-trace-snapshot.sh)
        return 0 2>/dev/null || exit 0
        ;;
esac

# Per-bash-process re-entry guard. The whole init runs once per process.
if [[ -n "${_VADE_BOOTSTRAP_TRACE_PROC_DONE:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_VADE_BOOTSTRAP_TRACE_PROC_DONE=1

_VTRACE_ROOT="${VADE_BOOTSTRAP_TRACE_DIR:-$HOME/.vade/traces}"
_VTRACE_CURRENT_FILE="$_VTRACE_ROOT/CURRENT_RUN_ID"
mkdir -p "$_VTRACE_ROOT" 2>/dev/null

# Run-id: reuse if a CURRENT marker points to a still-existing dir; else generate.
_VTRACE_RUN_ID=""
if [[ -s "$_VTRACE_CURRENT_FILE" ]]; then
    _candidate=$(cat "$_VTRACE_CURRENT_FILE" 2>/dev/null)
    [[ -n "$_candidate" && -d "$_VTRACE_ROOT/$_candidate" ]] && _VTRACE_RUN_ID="$_candidate"
fi
if [[ -z "$_VTRACE_RUN_ID" ]]; then
    _VTRACE_RUN_ID="bootstrap-trace-$(date -u +%Y%m%dT%H%M%S)-$$"
    mkdir -p "$_VTRACE_ROOT/$_VTRACE_RUN_ID/snapshots"
    echo "$_VTRACE_RUN_ID" > "$_VTRACE_CURRENT_FILE"
fi
export VADE_BOOTSTRAP_TRACE_RUN_ID="$_VTRACE_RUN_ID"
_VTRACE_DIR="$_VTRACE_ROOT/$_VTRACE_RUN_ID"

# Write meta.json on first init only.
if [[ ! -f "$_VTRACE_DIR/meta.json" ]]; then
    {
        printf '{\n'
        printf '  "run_id": "%s",\n' "$_VTRACE_RUN_ID"
        printf '  "started_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  "first_init_pid": %d,\n' "$$"
        printf '  "first_init_source": "%s",\n' "${BASH_SOURCE[0]:-unknown}"
        printf '  "first_init_invoker": "%s",\n' "${0:-unknown}"
        printf '  "bash_version": "%s"\n' "$BASH_VERSION"
        printf '}\n'
    } > "$_VTRACE_DIR/meta.json"
fi

# Open xtrace fd; redirect set -x output there.
# EPOCHREALTIME is bash 5+; PS4 falls back to SECONDS otherwise.
if exec {_VTRACE_FD}>>"$_VTRACE_DIR/xtrace.log" 2>/dev/null; then
    export BASH_XTRACEFD=$_VTRACE_FD
    # Per-command prefix. Evaluated by bash on each command trace.
    # Format: + [<epoch.ns>] [pid=N bp=N] [source.sh:line fn=NAME] <command>
    export PS4='+ [${EPOCHREALTIME:-$SECONDS}] [pid=$$ bp=${BASHPID:-$$}] [${BASH_SOURCE[0]##*/}:${LINENO} fn=${FUNCNAME[0]:-MAIN}] '
    set -x
fi

# Inotifywait: one watcher per trace run, owned by the first init invocation.
_VTRACE_INOTIFY_PID_FILE="$_VTRACE_DIR/inotify.pid"
if [[ ! -s "$_VTRACE_INOTIFY_PID_FILE" ]] || \
   ! kill -0 "$(<"$_VTRACE_INOTIFY_PID_FILE")" 2>/dev/null; then
    if command -v inotifywait >/dev/null 2>&1; then
        # Watch the three small mutable state dirs. Top-level only on /home/user
        # would be ideal, but inotifywait recursive on a small subset is fine.
        _watch_dirs=()
        for d in "$HOME/.claude" "$HOME/.vade" "$HOME/.vade-cloud-state"; do
            [[ -d "$d" ]] && _watch_dirs+=("$d")
        done
        if (( ${#_watch_dirs[@]} > 0 )); then
            (
                inotifywait -m -r -q \
                    -e create,modify,move,delete,close_write \
                    --format '%T|%w%f|%e' \
                    --timefmt '%Y-%m-%dT%H:%M:%S' \
                    "${_watch_dirs[@]}" 2>/dev/null \
                    >> "$_VTRACE_DIR/file-events.log"
            ) &
            echo $! > "$_VTRACE_INOTIFY_PID_FILE"
            disown 2>/dev/null
        fi
    else
        echo "no inotifywait available" > "$_VTRACE_DIR/inotify.skipped"
    fi
fi

# Snapshot at entry of this bash invocation.
_VTRACE_INVOCATION_TAG="${0##*/}"
if [[ -z "$_VTRACE_INVOCATION_TAG" || "$_VTRACE_INVOCATION_TAG" == "bash" ]]; then
    _VTRACE_INVOCATION_TAG="bash-${BASH_SOURCE[-1]##*/}"
    [[ "$_VTRACE_INVOCATION_TAG" == "bash-" ]] && _VTRACE_INVOCATION_TAG="bash-shell"
fi

_VTRACE_SNAPSHOT_BIN="${BASH_SOURCE[0]%/*}/bootstrap-trace-snapshot.sh"
if [[ -x "$_VTRACE_SNAPSHOT_BIN" ]]; then
    "$_VTRACE_SNAPSHOT_BIN" "$_VTRACE_INVOCATION_TAG-enter" "$_VTRACE_DIR" 2>/dev/null &
    disown 2>/dev/null
fi
