---
name: tagging-taxonomy
description: Apply or look up VADE issue labels. Use when filing, triaging, or searching issues across vade-app repos by dimension (type, area, readiness, priority, needs/blocked). Covers the v1 cross-repo taxonomy from MEMO 2026-04-22-09.
---

# VADE issue tagging taxonomy

The five `vade-app/*` repos (`vade-coo-memory`, `vade-runtime`,
`vade-core`, `vade-governance`, `vade-agent-logs`) share a
prefix-namespaced label scheme adopted via MEMO 2026-04-22-09. This
skill is a working digest. The canonical source is
`vade-coo-memory/coo/label_taxonomy.md` — read that file when the
digest below looks stale or incomplete.

## When to use this skill

Invoke when you need to:

- Apply labels to an issue you are filing or triaging.
- Pick the "next task to work on" — filter by `readiness:ready`.
- Route an issue to the right agent profile via `type:` + `area:`.
- Decide whether something is gated (`needs:*`, `blocked:*`).
- Check whether a label is valid, deprecated, or missing.

Don't invoke for: PR-level review labels (none defined), project-board
`State` / `Owner` fields (those live on the project, not on labels —
see `coo/label_taxonomy.md` § *"Project board"*), or commit-message
conventions (handled elsewhere).

## The five dimensions

Each issue gets labels from each dimension independently.

### 1. `type:*` — kind of work (exactly one)

| Label | Meaning |
|---|---|
| `type:bug` | Defect; behaviour diverges from intended |
| `type:feat` | New capability or user-facing behaviour |
| `type:chore` | Build, tooling, infra, housekeeping |
| `type:docs` | Documentation-only change |
| `type:refactor` | Internal restructure, no behaviour change |
| `type:test` | Test coverage, fixtures, harness |
| `type:research` | Spike or investigation — produces findings, not code |
| `type:epic` | Parent issue covering multiple implementable children |

GitHub defaults `bug` / `enhancement` / `documentation` are still
present; when both apply, the `type:*` value is canonical.

### 2. `area:*` — where in the system (one or two)

Prefix is universal; value list is per-repo. Adding a new `area:*`
value is unilateral — just create the label.

| Repo | Values |
|---|---|
| **Universal** (any repo) | `area:docs`, `area:ci`, `area:deploy` |
| `vade-coo-memory` | `area:memory`, `area:identity`, `area:agents`, `area:skills`, `area:governance` |
| `vade-runtime` | `area:cloud-env`, `area:mcp`, `area:bootstrap`, `area:hooks` |
| `vade-core` | `area:canvas`, `area:mcp`, `area:storage`, `area:auth`, `area:ui`, `area:cloud` |
| `vade-governance` | `area:authority`, `area:policy` |
| `vade-agent-logs` | `area:sessions`, `area:schema` |

### 3. `readiness:*` — agent-routable? (exactly one, or leave blank if untriaged)

**The headline dimension.** Drives agent assignment.

| Label | Meaning | Agent-routable? |
|---|---|---|
| `readiness:ready` | Well-scoped; approach clear; start today | **yes** |
| `readiness:needs-design` | Requires UX / API / architecture decisions | no |
| `readiness:needs-research` | Requires a spike before a plan exists | research agent |
| `readiness:needs-breakdown` | Too large / vague / coupled; decompose first | no |

Transitions: `needs-research` → spike lands → new or relabeled
`readiness:ready`. `needs-breakdown` → epic with children, parent
flips to `type:epic` + `readiness:ready` only once every child is
itself `ready` or worked.

### 4. `prio:*` — urgency (zero or one)

| Label | Meaning |
|---|---|
| `prio:P0` | Blocker; drop other work |
| `prio:P1` | High; next in queue |
| `prio:P2` | Normal; scheduled in current horizon |
| `prio:P3` | Backlog; someday/maybe |

Default is P2 if absent. Only label when it matters.

### 5. Qualifiers (zero or more)

| Label | Meaning |
|---|---|
| `needs:bdfl-approval` | Decision gate pending BDFL ack |
| `blocked:bdfl-go-ahead` | Externally blocked on BDFL before work starts |
| `blocked:upstream` | Blocked on a third-party change |
| `emancipatory` | Lowers the barrier for other humans/agents (MEMO 2026-04-20-01) |
| `external-code` | Integrates, audits, or cherry-picks third-party code |
| `good first issue` | GitHub default; genuinely approachable by a newcomer |
| `help wanted` | GitHub default; explicit ask for external contributions |

### Legacy — `proj:*` (retained, not extended)

`vade-coo-memory` has `proj:bootstrap`, `proj:pm-migration`,
`proj:workspace-relocate`, `proj:skills-research`, `proj:coo-identity`,
`proj:proposed-epic`. **Don't create new `proj:*` labels.** Use
`type:epic` + GitHub sub-issues for new parent/child linkage.

## Classification checklist

When asked to tag an issue, run this in order:

1. **Pick exactly one `type:*`.** If both `bug` and `feat` feel right,
   pick the one the reporter is actually asking for.
2. **Pick one or two `area:*`** from the repo's vocabulary. If none
   fit, create a new `area:*` label rather than force-fitting.
3. **Pick exactly one `readiness:*`** — **only if confident**. When
   the description is thin, leave `readiness:*` off (implicit
   "untriaged") rather than guess. `readiness:ready` means *a coding
   agent can start today*; be strict.
4. **Optionally add `prio:*`** — only if the issue signals urgency
   explicitly.
5. **Add any qualifiers** (`needs:*`, `blocked:*`, `emancipatory`,
   `external-code`) that apply.
6. **Apply with `gh`:**

   ```bash
   gh issue edit <N> --repo vade-app/<repo> \
     --add-label "type:feat,area:agents,readiness:ready"
   ```

   Or via the GitHub MCP `issue_write` tool.

## Search recipes — "what should I work on?"

Find issues a coding agent can take:

```bash
gh issue list --repo vade-app/vade-coo-memory \
  --label "readiness:ready" --state open
```

Find the research queue:

```bash
gh issue list --repo vade-app/vade-coo-memory \
  --label "readiness:needs-research" --state open
```

Blocked on BDFL (anywhere):

```bash
for r in vade-coo-memory vade-runtime vade-core vade-governance vade-agent-logs; do
  gh issue list --repo vade-app/$r --label "needs:bdfl-approval" --state open
done
```

Issues that need breakdown before anyone picks them up:

```bash
gh issue list --repo vade-app/<repo> \
  --label "readiness:needs-breakdown" --state open
```

Active work in a specific area across repos:

```bash
for r in vade-coo-memory vade-runtime vade-core vade-governance vade-agent-logs; do
  gh issue list --repo vade-app/$r --label "area:memory" --state open
done
```

Ready feature work in vade-core:

```bash
gh issue list --repo vade-app/vade-core \
  --label "type:feat,readiness:ready" --state open
```

## Routing hints (for future agent routers)

The taxonomy encodes inputs for a routing workflow. Skip unless
`readiness:ready`; then pick an agent profile from `type:` + `area:`:

| `type:` | `area:` | Suggested agent profile |
|---|---|---|
| `bug` | `canvas` | `claude-code-debug` + tldraw knowledge |
| `feat` | `mcp` | `claude-code` + MCP skill pack |
| `research` | any | `research-agent` (deep-research profile) |
| `docs` | any | Haiku-class model (cheap, fast) |
| `refactor` | any | `claude-code` + repo-aware `simplify` skill |

Gates: `needs:bdfl-approval` is a handshake; `blocked:*` is a hard
stop.

## Deprecated labels (do not apply to new issues)

Kept to avoid breaking closed-issue references. Map forward as shown:

| Old | New |
|---|---|
| `track:memory` | `area:memory` |
| `track:boot-opt` | `area:agents` (or `area:memory` by scope) |
| `track:orchestration` | `area:agents` |
| `track:self-assess` | `area:agents` |
| `docs-only` | `type:docs` |
| `canvas` (vade-core) | `area:canvas` |
| `feat` (vade-core) | `type:feat` |
| `milestone-1` (vade-core) | GitHub milestones |
| `Strategy` (vade-agent-logs) | `type:research` |
| `epic:ipad-live` | `type:epic` + sub-issues |
| `phase:3-pilot` | no replacement; use milestones |
| `Discussion-update`, `COO essay` | ad-hoc; consider retiring |

## Maintenance — what requires a memo

- **New `area:*` value** → unilateral; just create the label.
- **New `type:*` / `readiness:*` / `prio:*` value** → memo-worthy
  (cross-repo invariant).
- **New dimension** (sixth prefix) → memo-worthy.
- **Renaming an existing dimension** → memo-worthy.

Per-repo drift under `area:*` is allowed. Everything else is a
cross-repo invariant.

## Canonical source

```text
vade-coo-memory/coo/label_taxonomy.md
```

When this digest and the canonical doc disagree, the canonical doc
wins. Update this skill; don't drift the taxonomy.
