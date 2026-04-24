---
description: Commission an impartial project-historian retrospective on a scoped window of project work. Orchestrates two impartial evidence sub-agents (memos/essays analyst, PR/issue graph analyst) and produces a draft in the voice of commissions #1 and #2. Spec in vade-coo-memory/coo/culture_system_sop.md (SOP-CULTURE-001). Use the `--scope` form to dry-run a manifest without spawning sub-agents.
argument-hint: --since <YYYY-MM-DD> [--until <YYYY-MM-DD>] [--prs <list>] [--focus "<question>"] [--slug <slug>] [--open-pr] | --scope ...
allowed-tools: Bash, Read, Write, Task
---

Arguments: `$ARGUMENTS`

Follow the **commission-retrospective** skill to produce a historian-voiced retrospective. The full procedure, voice discipline, failure modes, and gate-check rules live in the skill body — this command file is the entrypoint, not the spec. SOP-CULTURE-001 is the canonical reference.

### Steps (summary)

1. **Resolve scope.** Run `bash /home/user/vade-runtime/scripts/commission-retrospective.sh --scope $ARGUMENTS` to emit a JSON manifest covering date window, merged PRs, memos, foundations essays, and prior commissions. If the manifest is empty across all four dimensions, stop and report — the window has no record.
2. **Impartial evidence sub-agents in parallel.** Spawn two `Task` sub-agents in a single message. Brief them with `templates/subagent-memos-brief.md` and `templates/subagent-pr-graph-brief.md` respectively, passing the manifest as context. Each sub-agent writes its report to the assigned `coo/_drafts/<date>-retrospective-<slug>-agent-<kind>.md` path.
3. **Historian draft.** Main instance reads both sub-agent reports, every file in `coo/retrospectives/`, and the relevant memos/essays. Produce the draft under `templates/historian-prompt.md` at `coo/_drafts/<date>-retrospective-<slug>.md`. Sections and voice per SOP-CULTURE-001 §2e/§2f.
4. **Gate check.** Run `bash /home/user/vade-runtime/scripts/integrity-check.sh`. If any of `groups.F.{F1,F2,F3,F4}` shows `ok: false` in `$VADE_CLOUD_STATE_DIR/integrity-check.json`, surface the `detail` strings into the PR body so the retrospective's own commit cannot silently capture the substrate it reports on.
5. **File PR.** If `$ARGUMENTS` includes `--open-pr`, call `commission-retrospective.sh --open-pr <slug>` — the shell wrapper opens a PR via `GH_TOKEN="$GITHUB_MCP_PAT" gh pr create` with title `[retrospective-draft] <slug>` and body citing manifest + reports + commissioning issue. Otherwise leave the drafts on disk for manual review.

### Critical constraints

- **Do not declare a cadence.** SOP §2b and commissions #1/#2 both refuse.
- **Do not skip step 4.** The gate check is how a retrospective earns its own citation discipline (F1) rather than exempting itself.
- **Do not synthesize around missing evidence.** If a sub-agent's report is empty or missing, say so in the draft; do not fill the gap.
- **Do not invoke for routine work.** SOP §2d lists triggers and anti-triggers; re-read the list before every commission.

### `--scope` dry-run

`/commission-retrospective --scope --since <date> ...` emits only the manifest JSON. Useful for previewing what a commission would cover before committing to the full flow.

See the `commission-retrospective` skill body for the graceful-degradation chain (no-Task fallback via `commission-retrospective.sh --manual`; no-`gh` local-draft mode; missing sub-agent report; missing `integrity-check.sh`).
