#!/usr/bin/env bash
# Post or update the bootstrap-regression PR comment.
#
# Identifies the prior comment by a magic header marker
# ("<!-- bootstrap-regression-comment -->") emitted by render-integrity-summary.sh
# so re-runs replace the previous comment instead of stacking duplicates.
#
# Required env (set by the workflow step):
#   GH_TOKEN         — token with issues:write
#   PR               — pull request number
#   REPO             — owner/name
# Optional env:
#   VADE_CI_SUMMARY_OUT — path to the rendered markdown summary
set -euo pipefail

SUMMARY="${VADE_CI_SUMMARY_OUT:-/tmp/bootstrap-regression-summary.md}"
HEADER='<!-- bootstrap-regression-comment -->'

if [ ! -f "$SUMMARY" ]; then
  echo "[ci-bootstrap-regression] summary file missing at $SUMMARY; nothing to post" >&2
  exit 0
fi
if [ -z "${PR:-}" ] || [ -z "${REPO:-}" ]; then
  echo "[ci-bootstrap-regression] PR or REPO unset; skipping comment" >&2
  exit 0
fi

EXISTING_ID="$(
  gh api "/repos/$REPO/issues/$PR/comments" --paginate \
    --jq ".[] | select(.body | startswith(\"$HEADER\")) | .id" \
    2>/dev/null | head -1 || true
)"

PAYLOAD="$(mktemp)"
trap 'rm -f "$PAYLOAD"' EXIT
jq -n --rawfile body "$SUMMARY" '{body: $body}' > "$PAYLOAD"

if [ -n "$EXISTING_ID" ]; then
  echo "[ci-bootstrap-regression] updating existing comment $EXISTING_ID"
  gh api --method PATCH "/repos/$REPO/issues/comments/$EXISTING_ID" \
    --input "$PAYLOAD" >/dev/null
else
  echo "[ci-bootstrap-regression] posting new comment on PR #$PR"
  gh api --method POST "/repos/$REPO/issues/$PR/comments" \
    --input "$PAYLOAD" >/dev/null
fi
