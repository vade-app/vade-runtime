---
description: Query the COO memo index (coo/memo_index.json) by memo ID, keyword, or date range. Returns matching entries with body-retrieval hints; full text is opt-in via the printed sed command.
argument-hint: [memo-id | keyword | YYYY-MM-DD..YYYY-MM-DD]
allowed-tools: Bash
---

!bash /home/user/vade-runtime/scripts/memo-query.sh "$ARGUMENTS"

Present the output above verbatim to the user inside a single fenced code block. Add no preamble, no summary, no commentary. If the output includes a `body: sed -n ...` line and the user clearly wants the full memo text, offer to run the printed `sed` command — don't run it automatically.
