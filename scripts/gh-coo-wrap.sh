#!/usr/bin/env bash
# gh-coo-wrap: append the Claude Code session URL to --body on
# COO-attributed `gh` writes, then run the real gh.
#
# Substrate enforcement of the rule in
# vade-coo-memory MEMO 2026-04-26-02 (issue #150). Carved out so the
# COO does not have to add the trail manually each turn — every
# attributable write that flows through `gh` carries the link back
# to the originating session.
#
# Marker (DO NOT REMOVE): COO-GH-COO-WRAP-MARKER-v1
#
# Behavior:
#   * Covered subcommands: `gh pr {create,edit,comment,review}` and
#     `gh issue {create,edit,comment}` — only when --body / -b /
#     --body-file is present (editor-flow and approve-only invocations
#     pass through unchanged).
#   * Source of URL: $CLAUDE_CODE_REMOTE_SESSION_ID (fallback
#     $CLAUDE_CODE_SESSION_ID), with `cse_` prefix stripped.
#   * Idempotent: bodies that already contain `claude.ai/code/session_`
#     are not re-augmented.
#   * Silent pass-through if no session URL is available (running
#     outside Claude Code) or the body is empty.
#   * Real gh located at $COO_GH_REAL (default
#     /home/user/.local/bin/gh-real). If absent, falls back to the
#     first `gh` on PATH whose directory differs from this wrapper's
#     and which does not itself carry the wrapper marker.

set -eu

WRAPPER_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
WRAPPER_DIR="$(dirname "$WRAPPER_PATH")"

# Resolve the real gh binary.
REAL_GH="${COO_GH_REAL:-/home/user/.local/bin/gh-real}"
if [ ! -x "$REAL_GH" ]; then
  REAL_GH=""
  oldifs="$IFS"; IFS=:
  for d in $PATH; do
    IFS="$oldifs"
    [ "$d" = "$WRAPPER_DIR" ] && { IFS=:; continue; }
    if [ -x "$d/gh" ] && ! grep -q 'COO-GH-COO-WRAP-MARKER-v1' "$d/gh" 2>/dev/null; then
      REAL_GH="$d/gh"
      break
    fi
    IFS=:
  done
  IFS="$oldifs"
fi

if [ -z "$REAL_GH" ] || [ ! -x "$REAL_GH" ]; then
  printf 'gh-coo-wrap: real gh binary not found (COO_GH_REAL=%s); refusing to run.\n' "${COO_GH_REAL:-unset}" >&2
  exit 127
fi

# Compute session URL once. Empty if outside Claude Code.
sid="${CLAUDE_CODE_REMOTE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
SESSION_URL=""
[ -n "$sid" ] && SESSION_URL="https://claude.ai/code/session_${sid#cse_}"

# is_covered <argv...>: returns 0 iff the (subcommand, action) pair
# parsed from argv falls in the augment-eligible set. Skips leading
# global flags so that e.g. `gh -R repo issue comment` is recognized
# the same as `gh issue comment -R repo`. Value-taking global flags
# in their separate-token form (`-R repo`, `--repo repo`,
# `--hostname host`) consume the following arg; `--flag=value` and
# boolean flags consume only themselves.
is_covered() {
  local sub="" act=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift ;;
      --*=*) shift ;;
      -R|--repo|--hostname)
        shift
        [ $# -gt 0 ] && shift
        ;;
      -*) shift ;;
      *)
        if [ -z "$sub" ]; then
          sub="$1"; shift
        else
          act="$1"; break
        fi
        ;;
    esac
  done
  case "$sub" in
    pr)
      case "$act" in create|edit|comment|review) return 0 ;; esac
      ;;
    issue)
      case "$act" in create|edit|comment) return 0 ;; esac
      ;;
  esac
  return 1
}

# augment <body>: prints body with session URL appended on a
# blank-line-separated trailing line. Returns body unchanged if:
#   * no session URL available
#   * body is empty
#   * body already contains a claude.ai/code/session_ link
augment() {
  local body="$1"
  if [ -z "$SESSION_URL" ] || [ -z "$body" ]; then
    printf '%s' "$body"
    return
  fi
  case "$body" in
    *"claude.ai/code/session_"*) printf '%s' "$body"; return ;;
  esac
  printf '%s\n\n%s' "$body" "$SESSION_URL"
}

# Pass-through: no session URL OR not a covered subcommand.
if [ -z "$SESSION_URL" ] || ! is_covered "$@"; then
  exec "$REAL_GH" "$@"
fi

# Walk args, augmenting --body / --body-file values.
declare -a new_args=()
declare -a tmp_files=()
cleanup() {
  if [ "${#tmp_files[@]}" -gt 0 ]; then
    rm -f "${tmp_files[@]}"
  fi
  return 0
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
  a="$1"
  case "$a" in
    --body|-b)
      shift
      body="${1:-}"
      new_args+=("$a" "$(augment "$body")")
      ;;
    --body=*)
      body="${a#--body=}"
      new_args+=("--body=$(augment "$body")")
      ;;
    -b=*)
      body="${a#-b=}"
      new_args+=("-b=$(augment "$body")")
      ;;
    --body-file)
      shift
      bf="${1:-}"
      if [ "$bf" = "-" ]; then
        body="$(cat)"
        new_args+=("--body" "$(augment "$body")")
      elif [ -f "$bf" ]; then
        body="$(cat "$bf")"
        tmp="$(mktemp)"
        tmp_files+=("$tmp")
        printf '%s' "$(augment "$body")" > "$tmp"
        new_args+=("--body-file" "$tmp")
      else
        new_args+=("--body-file" "$bf")
      fi
      ;;
    --body-file=*)
      bf="${a#--body-file=}"
      if [ "$bf" = "-" ]; then
        body="$(cat)"
        new_args+=("--body" "$(augment "$body")")
      elif [ -f "$bf" ]; then
        body="$(cat "$bf")"
        tmp="$(mktemp)"
        tmp_files+=("$tmp")
        printf '%s' "$(augment "$body")" > "$tmp"
        new_args+=("--body-file=$tmp")
      else
        new_args+=("$a")
      fi
      ;;
    *)
      new_args+=("$a")
      ;;
  esac
  shift
done

# Run real gh. Don't exec — we need the EXIT trap to clean up
# tmp files. gh reads --body-file synchronously, so the file is
# safe to remove after it returns.
"$REAL_GH" "${new_args[@]}"
exit $?
