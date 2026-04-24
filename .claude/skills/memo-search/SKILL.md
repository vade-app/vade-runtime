---
name: memo-search
description: Find memos in `coo/memos.md` by natural-language query via Mem0 semantic search over the `memo_pointer` layer. Use when the user asks "do we have memos about X?" or "what have we decided re: Y?", when keyword `/memo-query <word>` returned too few hits (titles + summaries are keyword-indexed but bodies are not), when the current task or plan context suggests prior COO decisions may be relevant, or when `/memo-query --semantic "<query>"` is invoked. Returns memo IDs + line ranges; the caller reads full text from `coo/memos.md` via the printed `sed` command. Don't rely on keyword `/memo-query` alone — it has an ~88% body-miss rate on concept queries (see MEMO 2026-04-24-04).
---

# memo-search — natural-language retrieval over the memo archive

The memo archive is a flat markdown file (`coo/memos.md`, ~45
memos, stable IDs `YYYY-MM-DD-NN`). The Mem0 `memo_pointer` layer
maintains one searchable record per memo (SOP-MEM-001 §2g). This
skill queries that layer and renders hits through the existing
memo-query template so output is format-identical to keyword mode.

## When to use this skill

Invoke when:

- The user asks a "do we have memos about X?" / "what's our
  current standing on Y?" / "have we dealt with Z before?"
  question. The archive's body text is not keyword-searchable;
  semantic is the only way to reach it.
- `/memo-query <keyword>` returned zero or few hits but the
  concept is likely discussed in some memo's body.
- You're mid-task and the working context (user prompt, recent
  tool results, active plan) hints that COO precedent exists.
  Searching is cheap; missing a precedent you should have cited
  is expensive.
- `/memo-query --semantic "<query>"` is invoked by the user.

Don't invoke for: fetching a memo by known ID (use
`/memo-query <id>` — faster and authoritative), date-range
browsing (`/memo-query YYYY-MM-DD..YYYY-MM-DD`), or writing new
memos.

## Why this exists

`/memo-query` without `--semantic` only searches memo IDs, titles,
and one-line summaries from `memo_index.json`. On a real query,
that misses most hits: the 2026-04-24 probe found 8 references to
"skill" across memo bodies, only 1 of which surfaced through the
title/summary index. The pointer layer closes that gap. MEMO
2026-04-24-04 has the rationale and the research trail.

## Procedure

### 1. Search Mem0

Call the Mem0 MCP search tool (usually `mcp__mem0__search_memories`)
with:

- `query`: the natural-language question or concept string, as
  phrased. Semantic search rewards fully-phrased queries — SOP §4
  notes *"What are the COO's standing rules for Mem0 writes?"*
  outperforms *"mem0 rules"*. Echo the user's phrasing unless
  they've been too terse.
- `filters`:
  `{AND: [{user_id: "ven"}, {metadata: {created_by: "coo"}}, {metadata: {memory_type: "memo_pointer"}}]}`
- `top_k`: 10 (a ceiling, not a target — return only what's
  actually relevant).

### 2. Collect memo_ids

For each hit, extract `metadata.memo_id`. Preserve the order —
Mem0's ranking is the ranking. De-duplicate (shouldn't happen
if the layer is synced correctly, but defend against it).

If zero hits:

- Likely stale layer — suggest `/memo-sync` and let the user
  re-run. A fresh sync is cheap (~45 records).
- Or the query genuinely has no match. Say so plainly; don't
  synthesise summaries or invent memo ids.

### 3. Render via the memo-query template

Invoke the bash renderer with the collected ids as a
comma-separated list:

```bash
bash /home/user/vade-runtime/scripts/memo-query.sh "--render-ids <id1>,<id2>,..."
```

This emits the same three-lines-per-memo shape the keyword mode
uses:

```
<id> (<date>) [<status>]  L<line_start>-<line_end>
  <summary_one_line>
  body: sed -n <line_start>,<line_end>p coo/memos.md
```

Using the bash helper keeps output consistent with every other
`/memo-query` mode — users don't re-learn the format per flag,
and a format change in one place updates all modes.

### 4. Present

Wrap the bash output in a single fenced code block. Header line
before the block, matching the keyword-mode convention:

```
=== N memos semantically matching "<query>" ===
```

If the user clearly wants full memo text for one of the hits,
offer to run the printed `sed -n <start>,<end>p coo/memos.md`
command. Don't proactively dump bodies — they're long and the
pointer is what matters.

## Failure modes

- **Mem0 MCP unreachable** (auth expired, 503, DNS cache overflow).
  Report the error plainly. Fall back to suggesting
  `/memo-query <keyword>` — id/keyword/date-range modes are
  bash-only and keep working without Mem0. Don't attempt to
  simulate semantic search against the markdown; it will mislead.
- **Zero hits despite a query that should match.** Likely stale
  layer. Suggest `/memo-sync`. Optionally re-run semantic search
  after the sync completes.
- **`--render-ids` not implemented in `memo-query.sh`.** This
  skill requires the `--render-ids <csv>` mode. If bash errors on
  that flag, the runtime has drifted — report and stop.

## Canonical source

```text
vade-coo-memory/coo/mem0_sop.md §2g (MEMO_POINTER schema)
vade-coo-memory/coo/mem0_sop.md §4 (retrieval discipline — phrasing, filters)
vade-runtime/scripts/memo-query.sh (--render-ids <csv> mode)
```

When this skill and the SOP disagree, the SOP wins. Update this
skill; don't drift the schema.
