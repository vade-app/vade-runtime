---
description: Query the COO memo index (coo/memo_index.json) by memo ID, keyword, date range, or natural-language semantic search. Semantic mode routes through the memo-search skill and the Mem0 `memo_pointer` layer.
argument-hint: [memo-id | keyword | YYYY-MM-DD..YYYY-MM-DD | --semantic "<query>"]
allowed-tools: Bash, Read, mcp__mem0__search_memories
---

!bash /home/user/vade-runtime/scripts/memo-query.sh "$ARGUMENTS"

Dispatch on `$ARGUMENTS`:

**If `$ARGUMENTS` starts with `--semantic` (the bash output above will be empty in this case — the script short-circuits semantic mode), follow the `memo-search` skill to run semantic retrieval:**

1. Extract the query text (everything after `--semantic`, trimmed).
2. Call `mcp__mem0__search_memories` with the natural-language query, filter `{AND: [{user_id: "ven"}, {metadata: {created_by: "coo"}}, {metadata: {memory_type: "memo_pointer"}}]}`, `top_k: 10`.
3. Collect `metadata.memo_id` from each hit in the order Mem0 returned them (ranking matters).
4. Render via the bash helper, passing the ids as a comma-separated list:
   `bash /home/user/vade-runtime/scripts/memo-query.sh "--render-ids <id1>,<id2>,..."`
5. Wrap the rendered output in a single fenced code block preceded by a header line in this shape:
   `=== N memos semantically matching "<query>" ===`
6. If a memo the user wants is in the results, offer to run its printed `sed -n <line_start>,<line_end>p coo/memos.md` to display the full body — don't dump bodies proactively.
7. If zero hits: the layer is probably stale. Suggest `/memo-sync` and say so plainly; don't fabricate matches. If Mem0 MCP is unreachable (auth failure, 503), report the error and suggest `/memo-query <keyword>` as the bash-only fallback.

**Otherwise (memo-id / keyword / date-range / --render-ids / empty), present the bash output above verbatim to the user inside a single fenced code block.** Add no preamble, no summary, no commentary. If the output includes a `body: sed -n ...` line and the user clearly wants the full memo text, offer to run the printed `sed` command — don't run it automatically.
