# VADE development container
# Base: Node 20 LTS on Debian Bookworm (slim variant)
# See versions.lock for pinned versions with rationale.
FROM node:20.19.1-bookworm-slim

# Non-root user for VS Code devcontainer convention. The 'node' user
# already exists in the base image (uid 1000); reuse it.
ARG USERNAME=node

# System packages: git for repo work, ca-certificates for npm/TLS,
# build tools for any native npm deps, curl for debugging, procps for
# tools like `ps` used by dev servers, openssh-client for git-over-ssh
# and ssh-keygen fingerprint validation, unzip for the 1Password CLI
# install path used by the COO identity bootstrap, python3 / python3-venv
# for the uv-managed mem0-mcp-server install below.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      ca-certificates \
      build-essential \
      curl \
      procps \
      openssh-client \
      unzip \
      python3 \
      python3-venv \
    && rm -rf /var/lib/apt/lists/*

# 1Password CLI — pinned in versions.lock. Baked at image-build time so
# the cloud snapshot-build path (cloud-setup.sh ensure_op_cli) and the
# SessionStart fallback never have to fetch from cache.agilebits.com
# mid-boot. Closes vade-runtime#111; advances epic #112 Stream 2
# (zero-egress boot). cloud-setup.sh's existing presence-check
# short-circuits when /usr/local/bin/op is on PATH.
ARG OP_VERSION=2.31.0
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in amd64|arm64) ;; *) echo "Unsupported arch: $arch" >&2; exit 1 ;; esac; \
    tmp="$(mktemp -d)"; \
    curl -fsSL --retry 5 --retry-delay 2 \
      "https://cache.agilebits.com/dist/1P/op2/pkg/v${OP_VERSION}/op_linux_${arch}_v${OP_VERSION}.zip" \
      -o "$tmp/op.zip"; \
    unzip -qo "$tmp/op.zip" -d "$tmp"; \
    install -m 0755 "$tmp/op" /usr/local/bin/op; \
    rm -rf "$tmp"; \
    op --version

# GitHub CLI — pinned in versions.lock. Same rationale as op:
# image-build-time once, no per-snapshot or per-session fetch.
# Required for COO attribution (`gh` is the canonical write path
# under vade-coo since github-coo MCP retired in epic #112 Stream 1).
ARG GH_VERSION=2.91.0
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in amd64|arm64) ;; *) echo "Unsupported arch: $arch" >&2; exit 1 ;; esac; \
    tmp="$(mktemp -d)"; \
    curl -fsSL --retry 5 --retry-delay 2 \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${arch}.tar.gz" \
      -o "$tmp/gh.tgz"; \
    tar -xzf "$tmp/gh.tgz" -C "$tmp"; \
    install -m 0755 "$tmp/gh_${GH_VERSION}_linux_${arch}/bin/gh" /usr/local/bin/gh; \
    rm -rf "$tmp"; \
    gh --version

# uv (Python package/tool installer) — pinned in versions.lock. Used
# only as the installer for mem0-mcp-server below. Pulled from the
# astral-sh GitHub release tarball (not `curl … | sh` from astral.sh)
# so the version is reproducible and the build doesn't shell-pipe
# whatever uv is current at image-build time. Same retry budget as op
# and gh.
ARG UV_VERSION=0.11.7
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) uv_arch="x86_64-unknown-linux-gnu" ;; \
      arm64) uv_arch="aarch64-unknown-linux-gnu" ;; \
      *) echo "Unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    tmp="$(mktemp -d)"; \
    curl -fsSL --retry 5 --retry-delay 2 \
      "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${uv_arch}.tar.gz" \
      -o "$tmp/uv.tgz"; \
    tar -xzf "$tmp/uv.tgz" -C "$tmp"; \
    install -m 0755 "$tmp/uv-${uv_arch}/uv" /usr/local/bin/uv; \
    install -m 0755 "$tmp/uv-${uv_arch}/uvx" /usr/local/bin/uvx; \
    rm -rf "$tmp"; \
    uv --version

# mem0-mcp-server stdio binary — pinned in versions.lock. uv-installed
# globally so the .mcp.json command path resolves at /usr/local/bin
# without a per-session uvx round-trip. Required for Mem0 MCP
# availability per vade-runtime#109; without it the .mcp.json stdio
# entry points at a missing binary and Mem0 surface stays dark.
ARG MEM0_MCP_VERSION=0.2.1
RUN set -eux; \
    UV_TOOL_BIN_DIR=/usr/local/bin UV_TOOL_DIR=/opt/uv-tools \
      /usr/local/bin/uv tool install --python python3 \
      "mem0-mcp-server==${MEM0_MCP_VERSION}"; \
    test -x /usr/local/bin/mem0-mcp-server

# Claude Code CLI (global install). Pinned in versions.lock.
# Install as root into /usr/local so all users can use it.
RUN npm install -g @anthropic-ai/claude-code@1.0.120 \
    && npm cache clean --force

# tsx globally so the MCP server can run without `npx` overhead in
# environments where npm cache isn't warm. vade-core still lists it
# as a devDependency.
RUN npm install -g tsx@4.21.0 \
    && npm cache clean --force

# Pre-create the library mount point with 'node' ownership so the
# named volume inherits correct permissions on first attach.
RUN mkdir -p /home/${USERNAME}/.vade/library/canvases \
             /home/${USERNAME}/.vade/library/entities \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.vade

# Standard devcontainer workspace mount point.
WORKDIR /workspace

# Drop to the 'node' user for runtime. VS Code will take over from here.
USER ${USERNAME}

# Expose documented ports so `docker run -p` works without surprise.
# Vite dev server = 5173, VADE MCP WebSocket bridge = 7600.
EXPOSE 5173 7600

# Default command: interactive bash. Devcontainer / docker run -it
# will give the operator a prompt inside /workspace.
CMD ["/bin/bash"]
