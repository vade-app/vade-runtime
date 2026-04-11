# vade-runtime

**Docker image and devcontainer for VADE.** Reproducible development
environment for the [VADE project](https://github.com/vade-app).
This repo produces the container that `vade-core` (and eventually
task-agent workspaces) run inside during development.

## Status

**Stub.** Bootstrap phase — no Dockerfile yet. Scaffolding begins
when `vade-core` has enough structure to need a pinned environment.

## Goals

- **Reproducible dev env** — one `devcontainer.json` that works on
  macOS, Linux, and (eventually) Windows.
- **Pinned toolchain** — Node.js 20 LTS, TypeScript, pnpm or npm
  (TBD), Rust stable, Python 3.12 for scientific helpers.
- **Cached layers** for fast iteration.
- **Claude Code friendly** — the container ships with `claude`
  CLI pre-installed and configured to read `/workspace/CLAUDE.md`.

## Planned layout

```
vade-runtime/
├── Dockerfile                ← base image
├── .devcontainer/
│   └── devcontainer.json     ← VS Code / Codespaces entry point
├── scripts/
│   ├── bootstrap.sh          ← first-run setup
│   └── healthcheck.sh        ← container smoke test
└── versions.lock             ← pinned tool versions
```

## How to use (once built)

```bash
# Clone vade-core next to this repo
git clone git@github.com:vade-app/vade-core.git ~/repos/vade-core
cd ~/repos/vade-core

# Open in VS Code with devcontainer
code .
# → "Reopen in Container" when prompted
```

Or via Docker directly:

```bash
docker pull ghcr.io/vade-app/vade-runtime:latest
docker run -it --rm -v "$PWD:/workspace" ghcr.io/vade-app/vade-runtime
```

## Governance

See [vade-governance](https://github.com/vade-app/vade-governance).
Changes to the runtime image affect every contributor's dev loop,
so BDFL review is required for any non-trivial modification.

## License

TBD — likely MIT or Apache-2.0, decided before the first external
contribution window.
