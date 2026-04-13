# Hermes Agent Railway Template

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/hermes-railway-template?referralCode=uTN7AS&utm_medium=integration&utm_source=template&utm_campaign=generic)

Deploy [Hermes Agent](https://github.com/NousResearch/hermes-agent) to Railway as a worker service with persistent state.

This template is worker-only: setup and configuration are done through Railway Variables, then the container bootstraps Hermes automatically on first run.

## What you get

- Hermes gateway running as a Railway worker
- First-boot bootstrap from environment variables
- Persistent Hermes state on a Railway volume at `/data`
- Telegram, Discord, or Slack support (at least one required)
- Multi-profile support: run multiple independent agents from one service

## How it works

1. You configure required variables in Railway.
2. On first boot, entrypoint initializes Hermes under `/data/.hermes`.
3. On future boots, the same persisted state is reused.
4. Container starts `hermes gateway` (plus one per additional profile).

## Railway deploy instructions

In Railway Template Composer:

1. Add a volume mounted at `/data`.
2. Deploy as a worker service.
3. Configure variables listed below.

Template defaults (already included in `railway.toml`):

- `HERMES_HOME=/data/.hermes`
- `HOME=/data`
- `MESSAGING_CWD=/data/workspace`

## Default environment variables

This template defaults to Telegram + OpenRouter. These are the default variables to fill when deploying:

```env
OPENROUTER_API_KEY=***
TELEGRAM_BOT_TOKEN=***
TELEGRAM_ALLOWED_USERS=""
```

You can add or change variables later in Railway service Variables.
For the latest supported variables and behavior, follow upstream Hermes documentation:

- https://github.com/NousResearch/hermes-agent
- https://github.com/NousResearch/hermes-agent/blob/main/README.md

## Required runtime variables

You must set:

- At least one inference provider config:
  - `OPENROUTER_API_KEY`, or
  - `OPENAI_BASE_URL` + `OPENAI_API_KEY`, or
  - `ANTHROPIC_API_KEY`
- At least one messaging platform:
  - Telegram: `TELEGRAM_BOT_TOKEN`
  - Discord: `DISCORD_BOT_TOKEN`
  - Slack: `SLACK_BOT_TOKEN` and `SLACK_APP_TOKEN`

Strongly recommended allowlists:

- `TELEGRAM_ALLOWED_USERS`
- `DISCORD_ALLOWED_USERS`
- `SLACK_ALLOWED_USERS`

Allowlist format examples (comma-separated, no brackets, no quotes):

- `TELEGRAM_ALLOWED_USERS=123456789,987654321`
- `DISCORD_ALLOWED_USERS=123456789012345678,234567890123456789`
- `SLACK_ALLOWED_USERS=U01234ABCDE,U09876WXYZ`

Use plain comma-separated values like `123,456,789`.
Do not use JSON or quoted arrays like `[123,456]` or `"123","456"`.

Optional global controls:

- `GATEWAY_ALLOW_ALL_USERS=true` (not recommended)

Provider selection tip:

- If you set multiple provider keys, set `HERMES_INFERENCE_PROVIDER` (for example: `openrouter`) to avoid auto-selection surprises.

## Multi-profile support

Run multiple independent Hermes agents from a single Railway service. Each profile gets its own gateway process, memory, sessions, skills, and configuration.

### Setup

1. Create profiles on the persistent volume (via Railway SSH or terminal):
   ```bash
   hermes profile create myprofile --clone
   ```
2. Set `HERMES_PROFILES` in Railway Variables:
   ```env
   HERMES_PROFILES=myprofile
   ```
3. For variables that differ between profiles, use pipe-separated values:
   ```env
   TELEGRAM_BOT_TOKEN=default-token|myprofile-token
   TELEGRAM_ALLOWED_USERS=111111111|222222222,111111111
   ```

### How pipe-separated values work

- Index 0 (left of first pipe) → default profile
- Index 1 → first profile in `HERMES_PROFILES`
- Index 2 → second profile, and so on
- **No pipe** → value is shared across all profiles
- Comma is preserved as an in-value separator (e.g. multiple allowed users)

Example with two profiles (`HERMES_PROFILES=alice,bob`):

```env
# Shared (all three profiles get the same key)
OPENROUTER_API_KEY=sk-shared-key

# Per-profile (index 0=default, 1=alice, 2=bob)
TELEGRAM_BOT_TOKEN=default-token|alice-token|bob-token
TELEGRAM_ALLOWED_USERS=111|222,111|333,111
TELEGRAM_HOME_CHANNEL=111|222|333
```

### Backward compatibility

If `HERMES_PROFILES` is unset and no env vars contain pipes, the entrypoint behaves exactly like a single-profile setup. No changes needed for existing deployments.

### Process management

Each profile runs its own `hermes gateway` process. If one crashes, only that gateway restarts (after 5 seconds). The others keep running. On Railway shutdown (SIGTERM), all gateways receive the signal and shut down gracefully.

### Profile configuration

Each profile's config, memory, and skills live on the persistent volume under `$HERMES_HOME/profiles/<name>/`. The entrypoint manages `.env` files automatically. Everything else (config.yaml, system prompt, skills, memory) is configured per-profile on the volume.

## Environment variable reference

For the full and up-to-date list, check out the [Hermes repository](https://github.com/NousResearch/hermes-agent).

## Simple usage guide

After deploy:

1. Start a chat with your bot on Telegram/Discord/Slack.
2. If using allowlists, ensure your user ID is included.
3. Send a normal message (for example: `hello`).
4. Hermes should respond via the configured model provider.

Helpful first checks:

- Confirm gateway logs show platform connection success.
- Confirm volume mount exists at `/data`.
- Confirm your provider variables are set and valid.

## Running Hermes commands manually

If you want to run `hermes ...` commands manually inside the deployed service (for example `hermes config`, `hermes model`, or `hermes pairing list`), use [Railway SSH](https://docs.railway.com/cli/ssh) to connect to the running container.

Example commands after connecting:

```bash
hermes status
hermes config
hermes model
hermes pairing list
hermes -p myprofile config   # for additional profiles
```

## Runtime behavior

Entrypoint (`scripts/entrypoint.sh`) does the following:

- Validates required provider and platform variables
- Writes runtime env to `${HERMES_HOME}/.env` (default profile, index 0)
- For each profile in `HERMES_PROFILES`: creates profile directory, writes profile `.env` (using pipe-separated index)
- Creates `${HERMES_HOME}/config.yaml` if missing
- Persists one-time marker `${HERMES_HOME}/.initialized`
- Starts `hermes gateway` for each profile (default + additional)
- Monitors all gateway processes; restarts any that crash

## Troubleshooting

- `401 Missing Authentication header`: provider/key mismatch (often wrong provider auto-selection or missing API key for selected provider).
- Bot connected but no replies: check allowlist variables and user IDs.
- Data lost after redeploy: verify Railway volume is mounted at `/data`.
- Profile gateway not starting: check `HERMES_PROFILES` is set and the profile directory exists on the volume.
- Wrong token for profile: verify pipe order matches profile order in `HERMES_PROFILES`.

## Build pinning

Docker build args:

- `HERMES_GIT_REF` (default: `main`)
- `NODE_MAJOR` (default: `22`)
- `PNPM_VERSION`
- `YARN_VERSION`
- `NPM_VERSION`
- `BUN_VERSION`
- `CLAUDE_CODE_VERSION`
- `CODEX_VERSION`
- `UV_VERSION`

Override in Railway if you want to pin a tag or commit.

## Local smoke test

```bash
docker build -t hermes-railway-template .

# Single profile (default behavior)
docker run --rm \
  -e OPENROUTER_API_KEY=*** \
  -e TELEGRAM_BOT_TOKEN=*** \
  -e TELEGRAM_ALLOWED_USERS=123456789 \
  -v "$(pwd)/.tmpdata:/data" \
  hermes-railway-template

# Multi-profile
docker run --rm \
  -e OPENROUTER_API_KEY=*** \
  -e HERMES_PROFILES=second \
  -e TELEGRAM_BOT_TOKEN="token1|token2" \
  -e TELEGRAM_ALLOWED_USERS="111|222,111" \
  -v "$(pwd)/.tmpdata:/data" \
  hermes-railway-template
```
