# VADE development container
# Base: Node 20 LTS on Debian Bookworm (slim variant)
# See versions.lock for pinned versions with rationale.
FROM node:20.19.1-bookworm-slim

# Non-root user for VS Code devcontainer convention. The 'node' user
# already exists in the base image (uid 1000); reuse it.
ARG USERNAME=node

# System packages: git for repo work, ca-certificates for npm/TLS,
# build tools for any native npm deps, curl for debugging, procps for
# tools like `ps` used by dev servers.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      ca-certificates \
      build-essential \
      curl \
      procps \
      openssh-client \
    && rm -rf /var/lib/apt/lists/*

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
