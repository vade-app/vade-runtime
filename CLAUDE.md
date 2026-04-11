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

Stub repository. No Dockerfile yet. The first concrete task is to
write a minimal `Dockerfile` based on `node:20-bookworm-slim` with
the `claude` CLI pre-installed, plus a `devcontainer.json` that
opens the image inside VS Code.
