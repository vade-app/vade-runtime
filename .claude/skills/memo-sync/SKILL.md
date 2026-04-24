---
name: memo-sync
description: Reconcile the Mem0 `memo_pointer` layer against `coo/memo_index.json` so the semantic search surface stays current with `coo/memos.md`. Use whenever a new or revised memo lands in `coo/memos.md`, when the user invokes `/memo-sync` or asks "is the semantic layer up to date?", when `/memo-query --semantic` misses a query you'd expect to match (probable staleness), or before ending a session in which a memo was issued. Implements SOP-MEM-001 §2g + §3 `infer=false` exception; do not skip a sync on the theory that "someone else will run it" — the layer goes stale silently.
---

# memo-sync — reconcile the memo-pointer semantic layer

Mem0 carries one `memo_pointer` record per memo in `coo/memos.md`.
Sync keeps that 1:1 mapping current. The markdown file is the source
of truth; Mem0 is a searchable pointer index. Authoritative spec:
`vade-coo-memory/coo/mem0_sop.md` §2g (schema) and §3 (the
`infer=false` exception).

## When to use this skill

Invoke when:

- A new memo has just been appended to `coo/memos.md` (or the index
  was just regenerated via `memo-index.sh`).
- The user runs `/memo-sync` or asks whether the semantic layer is
  current.
- `/memo-query --semantic "<query>"` returns zero or suspiciously
  few hits on a query you'd expect to match — stale layer is the
  likeliest cause.
- You're wrapping up a session in which a memo was issued; syncing
  now avoids the next session inheriting an out-of-date index.

Don't invoke for: indexing `memos.md` (that's `memo-index.sh`),
writing a memo (see `coo/memo_protocol.md`), or querying by known
id / keyword / date range (`/memo-query`).

## Why `infer=false` is load-bearing

Mem0's default ingestion pipeline runs LLM-driven fact extraction
and semantic dedupe on every write (SOP §3 "upserts and splits").
That behavior is appropriate for SOPs and session summaries, but
ruinous for an index: one submission can become several records,
and two similar memos can be silently merged. The semantic layer
only works if there is exactly one Mem0 record per `memo_id`.

`infer=false` stores the submitted text verbatim as a single
record, with metadata preserved exactly as passed. If the MCP
tool rejects the `infer` parameter, **stop and escalate** — do
not fall back to default inference, because the resulting layer
will be wrong in ways that are hard to see after the fact.

## Procedure

### 1. Load the current index

Read `/home/user/vade-coo-memory/coo/memo_index.json`. Each entry
carries `{id, date, status, title, summary_one_line, line_start,
line_end, supersedes}` — everything the pointer schema needs.

If the file is missing or empty, regenerate first:

```bash
bash /home/user/vade-runtime/scripts/memo-index.sh
```

### 2. Fetch current pointer records from Mem0

Call the Mem0 MCP search tool (usually `mcp__mem0__search_memories`)
with a blank query and a metadata filter scoped to memo-pointers
only:

- `filters`:
  `{AND: [{user_id: "ven"}, {metadata: {created_by: "coo"}}, {metadata: {memory_type: "memo_pointer"}}]}`
- `top_k`: ≥100 (a ceiling large enough to return every pointer;
  the corpus is ~45 memos today).

Build a map `{memo_id → [{mem0_id, metadata}, ...]}` from the
results. Any memo_id with more than one record is a sync bug from
a previous run — handle per §Failure modes below.

### 3. Diff

For each entry in the index:

- `memo_id` **not in Mem0** → **ADD**.
- `memo_id` **in Mem0 with changed `line_start`/`line_end`/`title`
  or `status`** → **REPLACE** (delete old, then add). SOP §3
  forbids bare re-add because Mem0 would silently merge into the
  existing record.
- `memo_id` **in Mem0 and unchanged** → NOOP.

For each pointer in Mem0 whose `memo_id` is NOT in the index:

- **STALE** → DELETE.

### 4. Execute the diff

For each ADD, call the Mem0 MCP add tool (usually
`mcp__mem0__add_memories`) with:

- **Text payload**: the memo's title followed by `. ` and then
  its `summary_one_line` from the index. One short string — Mem0
  does not need the full body (which stays in `memos.md`).
- `user_id`: `"ven"`
- `infer`: `false` — load-bearing, see above
- `metadata`:
  - `memory_type`: `"memo_pointer"`
  - `memo_id`, `line_start`, `line_end`, `date`, `status`,
    `supersedes` — from the index entry
  - `created_by`: `"coo"`
  - `retention`: `"durable"`
  - `source_session`: the current session's `run_id`

For each DELETE, call the Mem0 MCP delete tool with the stored
`mem0_id`.

For each REPLACE, run DELETE then ADD. Don't use `update` — SOP
§3 notes its idempotency is undocumented, and delete+add is the
only correctness path.

### 5. Report

One line per action, followed by a totals line. Example:

```
+ 2026-04-24-04 (add)
~ 2026-04-23-04 (replace; title changed)
- 2026-03-15-02 (delete; stale)
---
Sync complete: +1 ~1 -1 (42 unchanged).
```

If the run was a no-op: `Sync complete: 0 changes (45 unchanged).`
Always report, even when idle — the point is to confirm currency.

## Failure modes

- **Mem0 MCP unreachable** (auth failure, 503, DNS cache overflow
  mid-session). This is a regularly observed failure: the Mem0 MCP
  client does OAuth discovery once at session init and disables the
  server for the rest of the session if it hits a transient 503 on
  `mcp.mem0.ai/.well-known/oauth-authorization-server` (Cloudflare
  edge DNS-cache-overflow; diagnosis of 2026-04-24). Claude Code on
  the web has no `/mcp` re-init. When this happens:
  1. First check whether `$MEM0_API_KEY` is in env. If yes, fall
     back to the REST transport below — it talks to the same Mem0
     Platform through a different wire and the pointer writes are
     indistinguishable from the MCP ones.
  2. If no key, print the error, flag the semantic layer as
     out-of-date, and stop. Do not retry the MCP in a loop.
- **`infer` parameter rejected** by the MCP wrapper. Stop. Tell
  the user the wrapper version doesn't expose the flag we need,
  and point them at SOP §3 for why falling back to `infer=true`
  silently is not safe.
- **Index and `memos.md` disagree** (e.g., `memo-index.sh` just
  ran but the index still looks stale vs. the markdown). Bug
  upstream. Report line numbers of the disagreement; stop.
- **More than one Mem0 record shares a `memo_id`.** Previous sync
  left duplicates. Keep the newest by `created_at`; delete the
  rest; proceed. Report the cleanup in step 5.

## REST fallback — when the MCP transport is degraded

`/home/user/vade-runtime/scripts/mem0-rest.sh` is the break-glass
path. It uses `$MEM0_API_KEY` and calls Mem0 Platform's REST API
directly, bypassing MCP entirely. Same Platform, same data —
writes here are visible to MCP reads in a later session and vice
versa. Prefer MCP when it's healthy; use REST only when MCP is
down *and* the key is set.

Equivalent calls:

- **List pointer records** (equivalent to step 2 above):
  ```bash
  bash /home/user/vade-runtime/scripts/mem0-rest.sh list-memo-pointers
  ```
  Returns a JSON array. Extract `id` and `metadata.memo_id` from each.

- **Add** (step 4 ADD):
  ```bash
  bash /home/user/vade-runtime/scripts/mem0-rest.sh add-memo-pointer \
    <memo_id> <line_start> <line_end> <date> <status> \
    <supersedes|null> "<title>. <summary_one_line>" [run_id]
  ```
  Pass `null` literally for `supersedes` when the index entry has
  no supersession. The script hard-codes `infer=false` and fills
  in the standard metadata (`created_by`, `retention`,
  `source_session`).

- **Delete** (step 4 DELETE):
  ```bash
  bash /home/user/vade-runtime/scripts/mem0-rest.sh delete-memory <mem0_id>
  ```

- **Ping / auth check**:
  ```bash
  bash /home/user/vade-runtime/scripts/mem0-rest.sh ping
  ```
  Confirms the key is valid before running a full sync.

Report output is the same shape regardless of which transport was
used — the caller shouldn't need to care which path was taken, only
that it should prefer MCP and fall back to REST when needed.

## Canonical source

```text
vade-coo-memory/coo/mem0_sop.md §2g (MEMO_POINTER schema)
                                §3 (infer=false exception)
vade-coo-memory/coo/memo_index.json (the diff input)
```

When this skill and the SOP disagree, the SOP wins. Update this
skill; don't drift the schema.
