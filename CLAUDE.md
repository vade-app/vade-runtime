# vade-runtime — Repo Instructions for Claude Code

This repository produces the **reproducible development
environment** for VADE. Changes here affect every contributor's
loop, so treat them carefully.

## Session-start reading

1. This file.
2. `README.md`.
3. `Dockerfile` and `.devcontainer/devcontainer.json` (once they
   exist).
4. The public authority and decision-rights document at
   [vade-governance/authority.md](https://github.com/vade-app/vade-governance/blob/main/authority.md)
   — for what may and may not be done autonomously.

## Scope

Work in this repository is scoped to the development container and
toolchain pinning. Its job is to keep the dev environment clean,
pinned, and fast.

## What may be done autonomously

- Draft Dockerfile changes on a feature branch.
- Update pinned tool versions, with reasoning captured in the
  commit message.
- Add or revise scripts under `scripts/`.
- Open pull requests for review.
- Run local builds to verify changes (`docker build .`).

## What requires explicit approval

- Pushing image tags to any registry.
- Merging to `main`.
- Changing the base image family (e.g. from Debian to Alpine).
- Adding dependencies that aren't in-scope for VADE development.

## Pinning discipline

Every tool version added to the image must be pinned in
`versions.lock` (once that file exists) with rationale. Unpinned
dependencies cause silent dev-env drift across contributors, which
is the exact class of bug this repository exists to prevent.

## Current state

Alpha. Minimal Dockerfile in place (based on `node:20.19.1-bookworm-slim`)
with Claude Code CLI and `tsx` pre-installed. `.devcontainer/devcontainer.json`
forwards ports 5173 (Vite) and 7600 (MCP WebSocket bridge), and mounts
a named volume for the `~/.vade/library/` canvas library. `scripts/bootstrap.sh`
and `scripts/healthcheck.sh` handle first-run setup and smoke testing.
See `versions.lock` for pinned tools.

Next planned additions (deferred until needed): Rust toolchain via
`rustup` when the first performance module lands, Python 3.12 when a
canvas artifact needs scientific helpers.
