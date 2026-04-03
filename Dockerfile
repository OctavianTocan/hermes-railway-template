FROM python:3.11-slim AS builder

ARG HERMES_GIT_REF=main

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt
RUN git clone --depth 1 --branch "${HERMES_GIT_REF}" --recurse-submodules https://github.com/NousResearch/hermes-agent.git

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

RUN pip install --no-cache-dir --upgrade pip setuptools wheel
RUN pip install --no-cache-dir -e "/opt/hermes-agent[messaging,cron,cli,pty]"


FROM python:3.11-slim AS runtime-base

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    tini \
  && rm -rf /var/lib/apt/lists/*

ENV PATH="/opt/venv/bin:${PATH}" \
  PYTHONUNBUFFERED=1 \
  HERMES_HOME=/data/.hermes \
  HOME=/data

COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /opt/hermes-agent /opt/hermes-agent

WORKDIR /app
COPY scripts/entrypoint.sh /app/scripts/entrypoint.sh
RUN chmod +x /app/scripts/entrypoint.sh


FROM runtime-base AS dev

ARG NODE_MAJOR=22
ARG PNPM_VERSION=10.33.0
ARG YARN_VERSION=1.22.22
ARG NPM_VERSION=11.12.1
ARG BUN_VERSION=1.3.11
ARG CLAUDE_CODE_VERSION=2.1.91
ARG CODEX_VERSION=0.118.0
ARG UV_VERSION=0.11.3

# ── Core system packages + dev tools ────────────────────────────────────────
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    curl \
    wget \
    jq \
    tmux \
    vim \
    neovim \
    htop \
    tree \
    unzip \
    build-essential \
    openssh-client \
    sqlite3 \
    httpie \
    ripgrep \
    fd-find \
    python3-pip \
    python3-venv \
  && rm -rf /var/lib/apt/lists/*

# Symlink fd-find → fd (Debian/Ubuntu ships it as fdfind)
RUN ln -sf "$(command -v fdfind)" /usr/local/bin/fd 2>/dev/null || true

# ── Node.js + package managers ──────────────────────────────────────────────
RUN bash -o pipefail -c "curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -" \
  && apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs \
  && rm -rf /var/lib/apt/lists/* \
  && command -v node >/dev/null \
  && command -v npm >/dev/null \
  && corepack enable \
  && corepack prepare "pnpm@${PNPM_VERSION}" --activate \
  && corepack prepare "yarn@${YARN_VERSION}" --activate \
  && npm install -g "npm@${NPM_VERSION}"

# ── Bun ─────────────────────────────────────────────────────────────────────
RUN arch="$(dpkg --print-architecture)" \
  && case "${arch}" in \
      amd64) bun_arch='x64' ;; \
      arm64) bun_arch='aarch64' ;; \
      *) echo "Unsupported Bun architecture: ${arch}" >&2; exit 1 ;; \
    esac \
  && curl -fsSL "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-${bun_arch}.zip" -o /tmp/bun.zip \
  && unzip /tmp/bun.zip -d /opt/bun \
  && test -x "/opt/bun/bun-linux-${bun_arch}/bun" \
  && ln -sf "/opt/bun/bun-linux-${bun_arch}/bun" /usr/local/bin/bun \
  && ln -sf /usr/local/bin/bun /usr/local/bin/bunx \
  && rm -f /tmp/bun.zip

# ── AI coding CLIs ──────────────────────────────────────────────────────────
RUN npm install -g \
    "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    "@openai/codex@${CODEX_VERSION}"

# ── GitHub CLI (gh) ─────────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/*

# ── uv (fast Python package manager) ───────────────────────────────────────
RUN bash -o pipefail -c "curl -LsSf https://astral.sh/uv/${UV_VERSION}/install.sh | sh" \
  && test -x /root/.local/bin/uv \
  && test -x /root/.local/bin/uvx \
  && ln -sf /root/.local/bin/uv /usr/local/bin/uv \
  && ln -sf /root/.local/bin/uvx /usr/local/bin/uvx

ENTRYPOINT ["tini", "--"]
CMD ["/app/scripts/entrypoint.sh"]


FROM runtime-base AS runtime

ENTRYPOINT ["tini", "--"]
CMD ["/app/scripts/entrypoint.sh"]
