# vade-runtime

**Docker image and devcontainer for VADE.** Reproducible development
environment for the [VADE project](https://github.com/vade-app).
This repo produces the container that `vade-core` (and eventually
task-agent workspaces) run inside during development.

## Status

**Alpha.** Minimal Dockerfile and devcontainer are in place. Node 20
LTS + Claude Code CLI + tsx pre-installed. Targets the vade-core
Vite/tldraw/MCP stack.

## What's in the image

| Tool | Version | Why |
|------|---------|-----|
| Node.js | 20.19.1 LTS | Runtime for vade-core app and MCP server |
| @anthropic-ai/claude-code | 1.0.120 | Agent CLI inside the container |
| tsx | 4.21.0 | Run the vade-canvas MCP server |
| git, build-essential, ca-certificates, curl | bookworm | Dev essentials |

See [`versions.lock`](./versions.lock) for the full pinned list and
rationale.

## Layout

```
vade-runtime/
├── Dockerfile                ← base image
├── .devcontainer/
│   └── devcontainer.json     ← VS Code / Codespaces entry point
├── scripts/
│   ├── bootstrap.sh          ← first-run setup (npm install, dirs)
│   └── healthcheck.sh        ← smoke test: versions + PATH
└── versions.lock             ← pinned tool versions + rationale
```

## How to use

### With VS Code (recommended)

Copy (or symlink) the `.devcontainer/` folder into the vade-core
checkout, then:

```bash
cd ~/GitHub/VADE/repos/vade-core
code .
# → "Reopen in Container" when prompted
```

The container forwards port **5173** (Vite dev server) and **7600**
(VADE MCP WebSocket bridge). A named volume `vade-library` persists
`~/.vade/library/` across rebuilds.

### With Docker directly

```bash
docker build -t vade-runtime .
docker run -it --rm \
  -v "$PWD:/workspace" \
  -p 5173:5173 -p 7600:7600 \
  -v vade-library:/home/node/.vade \
  vade-runtime
```

### Verify the image

```bash
docker run --rm vade-runtime bash /workspace/scripts/healthcheck.sh
```

## Deferred

- **Rust** — planned for Phase 3+ performance modules. Add via
  `rustup` when the first Rust crate lands in vade-core.
- **Python 3.12** — planned for scientific helpers (numpy/scipy).
  Add when a canvas artifact needs it for agent-side computation.
- **pnpm** — TBD; sticking with npm until there's a concrete reason
  to switch.

## Governance

See [vade-governance](https://github.com/vade-app/vade-governance).
Changes to the runtime image affect every contributor's dev loop,
so BDFL review is required for any non-trivial modification.

## License

TBD — likely MIT or Apache-2.0, decided before the first external
contribution window.
