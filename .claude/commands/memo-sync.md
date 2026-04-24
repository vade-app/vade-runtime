---
description: Reconcile the Mem0 `memo_pointer` layer against `coo/memo_index.json` so natural-language memo search stays current with `coo/memos.md`. Routes through the memo-sync skill. Use `--dry-run` to see the plan without executing.
argument-hint: [--dry-run]
allowed-tools: Bash, Read, mcp__mem0__search_memories, mcp__mem0__add_memories, mcp__mem0__delete_memory
---

Arguments: `$ARGUMENTS`

Follow the **memo-sync** skill to reconcile Mem0 with the current `coo/memo_index.json`. The full procedure, failure modes, and the `infer=false` rationale are in the skill body — this command file is the entrypoint, not the spec.

### Steps (summary)

1. Read `/home/user/vade-coo-memory/coo/memo_index.json`. If the file is missing or empty, regenerate it first with `bash /home/user/vade-runtime/scripts/memo-index.sh`.
2. Fetch current pointer records: call `mcp__mem0__search_memories` with an empty query and filter
   `{AND: [{user_id: "ven"}, {metadata: {created_by: "coo"}}, {metadata: {memory_type: "memo_pointer"}}]}`,
   `top_k: 100`.
3. Build a map `{memo_id → [mem0_id, metadata]}` from the results. Any `memo_id` with more than one record is a previous-sync bug: keep the newest by `created_at`, plan to delete the rest.
4. Diff by `memo_id`:
   - entry in index but **not** in Mem0 → **ADD**
   - entry in Mem0 with `line_start` / `line_end` / `title` / `status` differing from the index → **REPLACE** (delete the old record first, then add — SOP-MEM-001 §3 forbids bare re-add)
   - entry in both and equal → **NOOP**
   - entry in Mem0 whose `memo_id` is not in the index → **DELETE** (stale)
5. If `$ARGUMENTS` includes `--dry-run`, print the plan (one line per action, then totals) and stop. Otherwise execute:
   - **ADD:** `mcp__mem0__add_memories` with the text payload = `<title>. <summary_one_line>` from the index entry; `user_id: "ven"`; **`infer: false`** (load-bearing); `metadata` = the full §2g schema plus standard fields (`created_by: "coo"`, `retention: "durable"`, `source_session: <run_id>`).
   - **DELETE:** `mcp__mem0__delete_memory` with the stored Mem0 record id.
   - **REPLACE:** DELETE then ADD; do not use an update tool (idempotency is undocumented).
6. Report, one line per action, then a totals line:
   ```
   + 2026-04-24-04 (add)
   ~ 2026-04-23-04 (replace; title changed)
   - 2026-03-15-02 (delete; stale)
   ---
   Sync complete: +1 ~1 -1 (42 unchanged).
   ```
   For a no-op run: `Sync complete: 0 changes (45 unchanged).`

### Critical constraints

- **`infer: false` on every add.** If the MCP tool rejects the parameter, stop — do NOT silently fall back to inferred ingestion. The whole semantic layer depends on a 1:1 mapping between memos and Mem0 records; default inference breaks that silently. SOP-MEM-001 §3 has the rationale.
- **Mem0 MCP unreachable:** if `$MEM0_API_KEY` is set, fall back to the REST path — `bash /home/user/vade-runtime/scripts/mem0-rest.sh {ping,list-memo-pointers,add-memo-pointer,delete-memory}` — same Platform via REST, same result. Otherwise print the error, state that the semantic layer is out of sync, stop. See the memo-sync skill's "REST fallback" section for the exact call shapes.

See the `memo-sync` skill body for edge cases (duplicate records, index/markdown drift) and the full REST fallback contract.
