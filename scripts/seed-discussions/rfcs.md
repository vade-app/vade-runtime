RFCs are where architecture and design get debated before code. Open one
when a decision will affect more than one feature, more than one agent,
or is hard to reverse.

## When to write an RFC

- Storage / transport / auth choices (e.g. the library storage driver
  shape; the MCP transport story)
- Cross-repo API contracts
- Anything introducing a new external dependency
- Workflow or governance changes that aren't purely operator-driven

## When NOT to write an RFC

- A single issue can hold the decision → just file the issue
- The decision is reversible and local to one file → just open the PR
- Taste-level preferences with no downstream impact

## RFC template (copy into a new post)

```
## Context
<what is the problem; why now; what's the current state>

## Proposal
<the recommended approach, concrete enough to act on>

## Alternatives considered
<2–3 alternatives with one-line trade-offs each>

## Open questions
<what we still don't know; who needs to weigh in>

## Decision log
<append one line per meaningful decision as the thread evolves>
```

## Lifecycle

1. **Draft** — posted. Tag affected feature leaders.
2. **Discussion** — comments converge, trade-offs documented.
3. **Decision** — BDFL or delegated authority posts a summary comment
   starting with `Decision:`. Update the decision log.
4. **Closure** — convert to an issue or doc PR. Link back. Close the thread.

## Conventions

- Title format: `[rfc] <concise subject>`.
- One RFC per decision. Don't bundle.
- If an RFC stalls >14 days, the author closes it as `withdrawn` or
  escalates to the BDFL.
