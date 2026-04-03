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


FROM python:3.11-slim

# ── Core system packages + dev tools ────────────────────────────────────────
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    tini \
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

# ── Node.js (latest LTS via nodesource) + package managers ─────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
  && apt-get install -y --no-install-recommends nodejs \
  && rm -rf /var/lib/apt/lists/* \
  && corepack enable \
  && corepack prepare pnpm@latest --activate \
  && corepack prepare yarn@stable --activate \
  && npm install -g npm@latest

# ── Bun ─────────────────────────────────────────────────────────────────────
RUN curl -fsSL https://bun.sh/install | bash \
  && ln -sf /root/.bun/bin/bun /usr/local/bin/bun \
  && ln -sf /root/.bun/bin/bunx /usr/local/bin/bunx

# ── AI coding CLIs ──────────────────────────────────────────────────────────
RUN npm install -g @anthropic-ai/claude-code @openai/codex

# ── GitHub CLI (gh) ─────────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/*

# ── uv (fast Python package manager) ───────────────────────────────────────
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
  && ln -sf /root/.local/bin/uv /usr/local/bin/uv \
  && ln -sf /root/.local/bin/uvx /usr/local/bin/uvx

# ── Hermes venv + source from builder ──────────────────────────────────────
ENV PATH="/opt/venv/bin:${PATH}" \
  PYTHONUNBUFFERED=1 \
  HERMES_HOME=/data/.hermes \
  HOME=/data

COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /opt/hermes-agent /opt/hermes-agent

WORKDIR /app
COPY scripts/entrypoint.sh /app/scripts/entrypoint.sh
RUN chmod +x /app/scripts/entrypoint.sh

ENTRYPOINT ["tini", "--"]
CMD ["/app/scripts/entrypoint.sh"]
