#!/usr/bin/env bash
set -euo pipefail

export HERMES_HOME="${HERMES_HOME:-/data/.hermes}"
export HOME="${HOME:-/data}"
export MESSAGING_CWD="${MESSAGING_CWD:-/data/workspace}"

INIT_MARKER="${HERMES_HOME}/.initialized"
ENV_FILE="${HERMES_HOME}/.env"
CONFIG_FILE="${HERMES_HOME}/config.yaml"

mkdir -p "${HERMES_HOME}" "${HERMES_HOME}/logs" "${HERMES_HOME}/sessions" "${HERMES_HOME}/cron" "${HERMES_HOME}/pairing" "${MESSAGING_CWD}"

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Multi-profile support ────────────────────────────────────────────────────
#
# Env vars can contain pipe-separated values for multi-profile setups.
# Index 0 = default profile, index 1+ = additional profiles from HERMES_PROFILES.
# If a var has no pipe, the single value is shared across all profiles.
#
# Example:
#   HERMES_PROFILES=esther
#   TELEGRAM_BOT_TOKEN=defaul...oken
#   OPENROUTER_API_KEY=***      (no pipe → same key for everyone)
#
# Comma is preserved as an in-value separator (e.g. allowed user lists).
#
# Per-profile env var exclusions:
#   HERMES_PROFILE_EXCLUDE_<NAME>=VAR1,VAR2,...
#   e.g. HERMES_PROFILE_EXCLUDE_ESTHER=SLACK_BOT_TOKEN,SLACK_APP_TOKEN
#   Excluded vars are not written to that profile's .env.

# Extract value at index $2 from pipe-separated string $1.
# Falls back to index 0 if the requested index doesn't exist (shared value).
get_profile_value() {
  local raw="$1" idx="${2:-0}"
  if [[ "$raw" != *"|"* ]]; then
    # No pipe → shared value, return as-is for every index.
    echo "$raw"
    return
  fi
  IFS='|' read -ra parts <<< "$raw"
  if [[ $idx -lt ${#parts[@]} ]]; then
    echo "${parts[$idx]}"
  else
    echo "${parts[0]}"
  fi
}

validate_platforms() {
  # Validate that at least one platform token exists in the raw env
  # (before pipe-splitting — any token at any index counts).
  local count=0

  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    count=$((count + 1))
  fi

  if [[ -n "${DISCORD_BOT_TOKEN:-}" ]]; then
    count=$((count + 1))
  fi

  if [[ -n "${SLACK_BOT_TOKEN:-}" || -n "${SLACK_APP_TOKEN:-}" ]]; then
    if [[ -z "${SLACK_BOT_TOKEN:-}" || -z "${SLACK_APP_TOKEN:-}" ]]; then
      echo "[bootstrap] ERROR: Slack requires both SLACK_BOT_TOKEN and SLACK_APP_TOKEN." >&2
      exit 1
    fi
    count=$((count + 1))
  fi

  if [[ "$count" -lt 1 ]]; then
    echo "[bootstrap] ERROR: Configure at least one platform: Telegram, Discord, or Slack." >&2
    exit 1
  fi
}

has_valid_provider_config() {
  # Check raw env (before pipe-split). Any provider key at any index counts.
  if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    return 0
  fi

  if [[ -n "${OPENAI_BASE_URL:-}" && -n "${OPENAI_API_KEY:-}" ]]; then
    return 0
  fi

  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    return 0
  fi

  return 1
}

# ── Env var passthrough list ─────────────────────────────────────────────────
# All vars that get written to each profile's .env.
# Pipe-separated values are resolved per-profile by write_env_file().

ENV_KEYS=(
  OPENROUTER_API_KEY OPENAI_API_KEY OPENAI_BASE_URL ANTHROPIC_API_KEY LLM_MODEL HERMES_INFERENCE_PROVIDER HERMES_PORTAL_BASE_URL NOUS_INFERENCE_BASE_URL HERMES_NOUS_MIN_KEY_TTL_SECONDS HERMES_DUMP_REQUESTS
  TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USERS TELEGRAM_ALLOW_ALL_USERS TELEGRAM_HOME_CHANNEL TELEGRAM_HOME_CHANNEL_NAME
  DISCORD_BOT_TOKEN DISCORD_ALLOWED_USERS DISCORD_ALLOW_ALL_USERS DISCORD_HOME_CHANNEL DISCORD_HOME_CHANNEL_NAME DISCORD_REQUIRE_MENTION DISCORD_FREE_RESPONSE_CHANNELS
  SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_ALLOWED_USERS SLACK_ALLOW_ALL_USERS SLACK_HOME_CHANNEL SLACK_HOME_CHANNEL_NAME WHATSAPP_ENABLED WHATSAPP_ALLOWED_USERS
  GATEWAY_ALLOW_ALL_USERS
  FIRECRAWL_API_KEY NOUS_API_KEY BROWSERBASE_API_KEY BROWSERBASE_PROJECT_ID BROWSERBASE_PROXIES BROWSERBASE_ADVANCED_STEALTH BROWSER_SESSION_TIMEOUT BROWSER_INACTIVITY_TIMEOUT FAL_KEY ELEVENLABS_API_KEY VOICE_TOOLS_OPENAI_KEY
  TINKER_API_KEY WANDB_API_KEY RL_API_URL GITHUB_TOKEN
  TERMINAL_ENV TERMINAL_BACKEND TERMINAL_DOCKER_IMAGE TERMINAL_SINGULARITY_IMAGE TERMINAL_MODAL_IMAGE TERMINAL_CWD TERMINAL_TIMEOUT TERMINAL_LIFETIME_SECONDS TERMINAL_CONTAINER_CPU TERMINAL_CONTAINER_MEMORY TERMINAL_CONTAINER_DISK TERMINAL_CONTAINER_PERSISTENT TERMINAL_SANDBOX_DIR TERMINAL_SSH_HOST TERMINAL_SSH_USER TERMINAL_SSH_PORT TERMINAL_SSH_KEY SUDO_PASSWORD
  WEB_TOOLS_DEBUG VISION_TOOLS_DEBUG MOA_TOOLS_DEBUG IMAGE_TOOLS_DEBUG CONTEXT_COMPRESSION_ENABLED CONTEXT_COMPRESSION_THRESHOLD CONTEXT_COMPRESSION_MODEL HERMES_MAX_ITERATIONS HERMES_TOOL_PROGRESS HERMES_TOOL_PROGRESS_MODE
  EXA_API_KEY FIREFLIES_API_KEY NOTION_API_KEY MISTRAL_API_KEY
  HINDSIGHT_API_URL HINDSIGHT_API_KEY
)

# Write a .env file for a given profile index.
# $1 = target .env path, $2 = profile index (0 = default), $3 = HERMES_HOME for this profile
# $4 = comma-separated list of env var names to exclude (optional)
write_env_file() {
  local target_env="$1" profile_idx="$2" profile_home="${3:-${HERMES_HOME}}" excludes="${4:-}"
  {
    echo "# Managed by entrypoint.sh (profile index ${profile_idx})"
    echo "HERMES_HOME=${profile_home}"
    echo "MESSAGING_CWD=${MESSAGING_CWD}"
  } > "$target_env"

  # Build an associative array of excluded keys for O(1) lookup
  declare -A exclude_map
  if [[ -n "$excludes" ]]; then
    IFS=',' read -ra exclude_list <<< "$excludes"
    for ex in "${exclude_list[@]}"; do
      ex="$(echo "$ex" | tr -d '[:space:]')"
      [[ -n "$ex" ]] && exclude_map["$ex"]=1
    done
  fi

  for key in "${ENV_KEYS[@]}"; do
    [[ -n "${exclude_map[$key]+x}" ]] && continue
    local raw="${!key:-}"
    if [[ -n "$raw" ]]; then
      local resolved
      resolved="$(get_profile_value "$raw" "$profile_idx")"
      printf '%s=%s\n' "$key" "$resolved" >> "$target_env"
    fi
  done
}

# ── Validation ───────────────────────────────────────────────────────────────

if ! has_valid_provider_config; then
  echo "[bootstrap] ERROR: Configure a provider: OPENROUTER_API_KEY, or OPENAI_BASE_URL+OPENAI_API_KEY, or ANTHROPIC_API_KEY." >&2
  exit 1
fi

validate_platforms

# ── Write default profile .env (index 0) ─────────────────────────────────────

echo "[bootstrap] Writing runtime env to ${ENV_FILE}"
write_env_file "$ENV_FILE" 0

# ── Bootstrap additional profiles ─────────────────────────────────────────────

IFS=',' read -ra PROFILES <<< "${HERMES_PROFILES:-}"
PROFILE_INDEX=1

for profile_name in "${PROFILES[@]}"; do
  # Skip empty entries (e.g. trailing comma)
  profile_name="$(echo "$profile_name" | tr -d '[:space:]')"
  [[ -z "$profile_name" ]] && continue

  PROFILE_DIR="${HERMES_HOME}/profiles/${profile_name}"
  PROFILE_ENV="${PROFILE_DIR}/.env"

  mkdir -p "${PROFILE_DIR}" "${PROFILE_DIR}/logs" "${PROFILE_DIR}/sessions" "${PROFILE_DIR}/skills" "${PROFILE_DIR}/cron" "${PROFILE_DIR}/pairing"

  # Check for per-profile env var exclusions: HERMES_PROFILE_EXCLUDE_<NAME>
  local_exclude_var="HERMES_PROFILE_EXCLUDE_$(echo "$profile_name" | tr '[:lower:]' '[:upper:]')"
  local_excludes="${!local_exclude_var:-}"

  echo "[bootstrap] Writing runtime env for profile '${profile_name}' (index ${PROFILE_INDEX})"
  [[ -n "$local_excludes" ]] && echo "[bootstrap]   excluding: ${local_excludes}"
  write_env_file "$PROFILE_ENV" "$PROFILE_INDEX" "$PROFILE_DIR" "$local_excludes"

  PROFILE_INDEX=$((PROFILE_INDEX + 1))
done

# ── First-time init + config ─────────────────────────────────────────────────

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "[bootstrap] Creating ${CONFIG_FILE}"
  cat > "$CONFIG_FILE" <<EOF
terminal:
  backend: ${TERMINAL_ENV:-${TERMINAL_BACKEND:-local}}
  cwd: ${TERMINAL_CWD:-/data/workspace}
  timeout: ${TERMINAL_TIMEOUT:-180}
compression:
  enabled: true
  threshold: 0.85
EOF
fi

if [[ ! -f "$INIT_MARKER" ]]; then
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$INIT_MARKER"
  echo "[bootstrap] First-time initialization completed."
else
  echo "[bootstrap] Existing Hermes data found. Skipping one-time init."
fi

if [[ -z "${TELEGRAM_ALLOWED_USERS:-}${DISCORD_ALLOWED_USERS:-}${SLACK_ALLOWED_USERS:-}" ]]; then
  if ! is_true "${GATEWAY_ALLOW_ALL_USERS:-}" && ! is_true "${TELEGRAM_ALLOW_ALL_USERS:-}" && ! is_true "${DISCORD_ALLOW_ALL_USERS:-}" && ! is_true "${SLACK_ALLOW_ALL_USERS:-}"; then
    echo "[bootstrap] WARNING: No allowlists configured. Gateway defaults to deny-all; use DM pairing or set *_ALLOWED_USERS." >&2
  fi
fi

# ── Launch gateways ──────────────────────────────────────────────────────────

# Associative array: PID → label (for restart tracking)
declare -A GATEWAY_PIDS
declare -A GATEWAY_CMDS

start_gateway() {
  local label="$1"
  shift
  "$@" &
  local pid=$!
  GATEWAY_PIDS[$pid]="$label"
  GATEWAY_CMDS[$pid]="$*"
  echo "[bootstrap] Started gateway '${label}' (PID ${pid})"
}

# Forward SIGTERM/SIGINT to all children for graceful shutdown
cleanup() {
  echo "[bootstrap] Shutting down all gateways..."
  for pid in "${!GATEWAY_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
  wait
  exit 0
}
trap cleanup SIGTERM SIGINT

echo "[bootstrap] Starting Hermes gateways..."

# Default profile gateway
start_gateway "default" hermes gateway

# Additional profile gateways
for profile_name in "${PROFILES[@]}"; do
  profile_name="$(echo "$profile_name" | tr -d '[:space:]')"
  [[ -z "$profile_name" ]] && continue
  start_gateway "$profile_name" hermes -p "$profile_name" gateway
done

# Restart loop: if any gateway exits, restart only that one.
while true; do
  # wait -n exits when any child terminates, returns its exit code.
  set +e
  wait -n -p EXITED_PID
  exit_code=$?
  set -e

  if [[ -n "${EXITED_PID:-}" && -n "${GATEWAY_PIDS[$EXITED_PID]+x}" ]]; then
    label="${GATEWAY_PIDS[$EXITED_PID]}"
    cmd="${GATEWAY_CMDS[$EXITED_PID]}"
    unset "GATEWAY_PIDS[$EXITED_PID]"
    unset "GATEWAY_CMDS[$EXITED_PID]"
    echo "[bootstrap] Gateway '${label}' exited (code=${exit_code}), restarting in 5s..."
    sleep 5
    start_gateway "$label" $cmd
  fi
done
