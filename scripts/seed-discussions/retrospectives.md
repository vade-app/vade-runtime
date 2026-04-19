Retrospectives happen per milestone and per significant session.
The goal is concrete, low-overhead learning — not ritual.

## Cadence

- **Milestone retros** — one pinned thread per milestone (e.g.
  `[retro] M1: iPad-live`). Opened when the milestone epic closes.
- **Session retros** — optional, for sessions that produced unexpected
  outcomes (wins or regressions).

## Post template

```
## What went well
<2–4 bullets, concrete>

## What didn't
<2–4 bullets, concrete; no blame>

## What we'll do differently
<1–3 bullets, each with an owner and a next step — an issue, a doc PR,
or a governance change>

## Metrics
<cycle time, merge rate, bug rate if available; skip if noisy>
```

## Conventions

- Title format: `[retro] <milestone or session name>`.
- Every "what we'll do differently" item must convert into an issue
  before the thread is closed. No retro promises die in the thread.
- Keep the tone analytic. Agents and operators both contribute; author
  attribution is implicit via commit/post identity.
- Pin the retro thread until the follow-up issues close.
