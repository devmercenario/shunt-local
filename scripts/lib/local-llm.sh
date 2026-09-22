#!/bin/bash
# Shared Local LLM plumbing for shunt-local delegation scripts.
# Connects to any OpenAI-compatible completions endpoint (llama.cpp / llama-server, Ollama, vLLM).

# Default settings
DEFAULT_ENDPOINT="http://127.0.0.1:8080/v1/chat/completions"
DEFAULT_MODEL="Qwen/Qwen2.5-Coder-7B-Instruct-GGUF"
DEFAULT_TEMPERATURE="0.2"
DEFAULT_MIN_LINES=350
DEFAULT_TIMEOUT_SECONDS=180

shunt_load_config() {
  local cfg_file=""
  if [ -n "${SHUNT_CONFIG_PATH:-}" ] && [ -f "${SHUNT_CONFIG_PATH}" ]; then
    cfg_file="${SHUNT_CONFIG_PATH}"
  elif [ "${SHUNT_ALLOW_PROJECT_CONFIG:-}" = "true" ] && [ -f "./shunt.config.json" ]; then
    cfg_file="./shunt.config.json"
  elif [ -f "$HOME/.config/shunt-local/config.json" ]; then
    cfg_file="$HOME/.config/shunt-local/config.json"
  fi

  if [ -n "$cfg_file" ] && command -v jq >/dev/null 2>&1; then
    local cfg_endpoint cfg_model cfg_temp cfg_timeout cfg_key cfg_min_lines
    local cfg_enabled cfg_hook_view cfg_hook_run
    cfg_endpoint=$(jq -r '.endpoint // empty' "$cfg_file" 2>/dev/null)
    cfg_model=$(jq -r '.model // empty' "$cfg_file" 2>/dev/null)
    cfg_temp=$(jq -r '.temperature // empty' "$cfg_file" 2>/dev/null)
    cfg_timeout=$(jq -r '.timeout_seconds // empty' "$cfg_file" 2>/dev/null)
    cfg_key=$(jq -r '.api_key // empty' "$cfg_file" 2>/dev/null)
    cfg_min_lines=$(jq -r '.min_lines // empty' "$cfg_file" 2>/dev/null)
    cfg_enabled=$(jq -r 'if .enabled == null then "" else .enabled end' "$cfg_file" 2>/dev/null)
    cfg_hook_view=$(jq -r 'if .hooks.view_file == null then "" else .hooks.view_file end' "$cfg_file" 2>/dev/null)
    cfg_hook_run=$(jq -r 'if .hooks.run_command == null then "" else .hooks.run_command end' "$cfg_file" 2>/dev/null)

    [ -z "${SHUNT_ENDPOINT:-}" ] && [ -n "$cfg_endpoint" ] && SHUNT_ENDPOINT="$cfg_endpoint"
    [ -z "${SHUNT_MODEL:-}" ] && [ -n "$cfg_model" ] && SHUNT_MODEL="$cfg_model"
    [ -z "${SHUNT_TEMPERATURE:-}" ] && [ -n "$cfg_temp" ] && SHUNT_TEMPERATURE="$cfg_temp"
    [ -z "${SHUNT_TIMEOUT_SECONDS:-}" ] && [ -n "$cfg_timeout" ] && SHUNT_TIMEOUT_SECONDS="$cfg_timeout"
    [ -z "${SHUNT_API_KEY:-}" ] && [ -n "$cfg_key" ] && SHUNT_API_KEY="$cfg_key"
    [ -z "${SHUNT_MIN_LINES:-}" ] && [ -n "$cfg_min_lines" ] && SHUNT_MIN_LINES="$cfg_min_lines"
    [ -z "${SHUNT_ENABLED:-}" ] && [ -n "$cfg_enabled" ] && SHUNT_ENABLED="$cfg_enabled"
    [ -z "${SHUNT_HOOK_VIEW_FILE:-}" ] && [ -n "$cfg_hook_view" ] && SHUNT_HOOK_VIEW_FILE="$cfg_hook_view"
    [ -z "${SHUNT_HOOK_RUN_COMMAND:-}" ] && [ -n "$cfg_hook_run" ] && SHUNT_HOOK_RUN_COMMAND="$cfg_hook_run"
  fi

  SHUNT_ENDPOINT="${SHUNT_ENDPOINT:-$DEFAULT_ENDPOINT}"
  SHUNT_MODEL="${SHUNT_MODEL:-$DEFAULT_MODEL}"
  SHUNT_TEMPERATURE="${SHUNT_TEMPERATURE:-$DEFAULT_TEMPERATURE}"
  SHUNT_TIMEOUT_SECONDS="${SHUNT_TIMEOUT_SECONDS:-$DEFAULT_TIMEOUT_SECONDS}"
  SHUNT_MIN_LINES="${SHUNT_MIN_LINES:-$DEFAULT_MIN_LINES}"
  SHUNT_API_KEY="${SHUNT_API_KEY:-}"
  SHUNT_ENABLED="${SHUNT_ENABLED:-true}"
  SHUNT_HOOK_VIEW_FILE="${SHUNT_HOOK_VIEW_FILE:-true}"
  SHUNT_HOOK_RUN_COMMAND="${SHUNT_HOOK_RUN_COMMAND:-true}"
}

shunt_load_config

# Security: validate endpoint to prevent config hijacking (C2, H1, H2)
shunt_validate_endpoint() {
  local endpoint="$1"
  local scheme host rest

  # Reject URLs with embedded userinfo (e.g. http://127.0.0.1:8080@evil.com) —
  # this can spoof the host that actually receives the data.
  case "$endpoint" in
    *@*)
      echo "🔒 BLOCKED: endpoint URL contains embedded credentials (@)." >&2
      echo "   This can spoof the host used for data transmission." >&2
      return 1
      ;;
  esac

  # Extract scheme and host from the URL.
  scheme=$(echo "$endpoint" | sed -nE 's|^([a-zA-Z][a-zA-Z0-9+.-]*)://.*|\1|p')
  rest=$(echo "$endpoint" | sed -E 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||')
  host=$(echo "$rest" | sed -E 's|[:/].*||')
  [ -n "$scheme" ] || scheme="http"
  scheme=$(printf '%s' "$scheme" | tr '[:upper:]' '[:lower:]')

  # Only HTTP(S) are valid transports for an OpenAI-compatible endpoint. Without
  # this, schemes like file://, gopher:// or ftp:// could slip past the remote
  # checks below and make curl send source code to an unexpected destination.
  case "$scheme" in
    http|https) ;;
    *)
      echo "🔒 BLOCKED: unsupported endpoint scheme '${scheme}://'." >&2
      echo "   Only http:// (localhost) and https:// (remote, opt-in) are allowed." >&2
      return 1
      ;;
  esac

  # Localhost endpoints are always safe.
  case "$host" in
    127.0.0.1|localhost|'[::1]'|::1|0.0.0.0) return 0 ;;
  esac

  # ANY non-localhost endpoint (HTTP or HTTPS) requires explicit opt-in. Without
  # this, an HTTPS endpoint in a project config would silently exfiltrate source.
  if [ "${SHUNT_ALLOW_REMOTE:-}" != "true" ]; then
    echo "🔒 BLOCKED: Non-localhost endpoint '$endpoint' is not allowed by default." >&2
    echo "   Your source code and prompts would be transmitted to a remote server." >&2
    echo "   Set SHUNT_ALLOW_REMOTE=true to explicitly allow remote endpoints." >&2
    return 1
  fi

  # Remote endpoints are only allowed over TLS; plain HTTP is never acceptable.
  if [ "$scheme" = "http" ]; then
    echo "🔒 BLOCKED: plain HTTP to non-localhost is not allowed." >&2
    echo "   Your source code would be transmitted in cleartext. Use HTTPS." >&2
    return 1
  fi

  return 0
}

# Warn at load time if a project config exists but is not enabled (potential poisoning).
# Project configs are only honored with an explicit SHUNT_ALLOW_PROJECT_CONFIG=true.
if [ -f "./shunt.config.json" ] && [ "${SHUNT_ALLOW_PROJECT_CONFIG:-}" != "true" ]; then
  echo "⚠️  shunt-local: ./shunt.config.json detected but IGNORED (requires SHUNT_ALLOW_PROJECT_CONFIG=true)." >&2
fi

shunt_is_enabled() {
  local disabled_file="${HOME}/.config/shunt-local/disabled"
  if [ -f "$disabled_file" ]; then
    return 1
  fi
  if [ "$SHUNT_ENABLED" = "false" ] || [ "$SHUNT_ENABLED" = "0" ]; then
    return 1
  fi
  return 0
}

shunt_hook_is_enabled() {
  local hook_name="$1"
  if ! shunt_is_enabled; then
    return 1
  fi
  case "$hook_name" in
    view_file)
      if [ "$SHUNT_HOOK_VIEW_FILE" = "false" ] || [ "$SHUNT_HOOK_VIEW_FILE" = "0" ]; then
        return 1
      fi
      ;;
    run_command)
      if [ "$SHUNT_HOOK_RUN_COMMAND" = "false" ] || [ "$SHUNT_HOOK_RUN_COMMAND" = "0" ]; then
        return 1
      fi
      ;;
  esac
  return 0
}

# Temporary file management with automatic cleanup on main process exit
SHUNT_TMPFILES=()
SHUNT_PID="$$"

shunt_cleanup() {
  if [ "$$" -eq "$SHUNT_PID" ]; then
    rm -f "${SHUNT_TMPFILES[@]}" 2>/dev/null || true
  fi
}
trap shunt_cleanup EXIT INT TERM

shunt_tmpfile() {
  local f
  local old_umask
  old_umask=$(umask)
  umask 077
  f=$(mktemp) || { umask "$old_umask"; return 1; }
  umask "$old_umask"
  SHUNT_TMPFILES+=("$f")
  printf -v "$1" '%s' "$f"
}

# Write the Authorization header to a 0600 temp file and expose its path. Using
# curl --config keeps the API key out of the process argument list (visible to
# other local users via ps / /proc/<pid>/cmdline).
shunt_auth_config_file() {
  [ -z "${SHUNT_API_KEY:-}" ] && return 1
  local f
  shunt_tmpfile f || return 1
  local key="${SHUNT_API_KEY//$'\n'/}"
  key="${key//$'\r'/}"
  key="${key//\\/\\\\}"
  key="${key//\"/\\\"}"
  printf 'header = "Authorization: Bearer %s"\n' "$key" > "$f"
  printf -v "$1" '%s' "$f"
  return 0
}

shunt_preflight() {
  local missing=""
  command -v jq >/dev/null 2>&1 || missing="$missing jq"
  command -v curl >/dev/null 2>&1 || missing="$missing curl"

  if [ -n "$missing" ]; then
    echo "Error: missing required command(s):$missing" >&2
    echo "Please install them via your package manager." >&2
    return 1
  fi
  return 0
}

shunt_is_online() {
  [ "${__SHUNT_TEST_MOCK_ONLINE:-}" = "1" ] && return 0

  # Refuse to health-check a disallowed endpoint. This prevents a config-poisoned
  # endpoint from becoming a beacon on every hook invocation (and leaking the API
  # key in the Authorization header). Fail closed => hooks fail open to the cloud.
  shunt_validate_endpoint "$SHUNT_ENDPOINT" >/dev/null 2>&1 || return 1

  local base="${SHUNT_ENDPOINT%/}"
  local health_url
  if [[ "$base" == */v1/chat/completions ]]; then
    health_url="${base%/v1/chat/completions}/v1/models"
  else
    health_url="$base"
  fi

  # Only send the API key to localhost endpoints; never to remote hosts.
  local auth_args=()
  if [ -n "${SHUNT_API_KEY:-}" ]; then
    local health_host
    health_host=$(echo "$SHUNT_ENDPOINT" | sed -E 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||' | sed -E 's|[:/].*||')
    case "$health_host" in
      127.0.0.1|localhost|'[::1]'|::1|0.0.0.0)
        local health_auth_cfg
        if shunt_auth_config_file health_auth_cfg; then
          auth_args=(--config "$health_auth_cfg")
        fi
        ;;
    esac
  fi
  curl -s -S --connect-timeout 0.1 -m 0.3 "${auth_args[@]}" "$health_url" >/dev/null 2>&1
}

shunt_report_error() {
  local label="$1" response="$2"
  local message
  message=$(printf '%s' "$response" | jq -r '.error.message // .error // empty' 2>/dev/null)

  if [ -n "$message" ]; then
    echo "Error: $label: $message" >&2
  else
    echo "Error: $label" >&2
    printf '%s\n' "$response" >&2
  fi
}

shunt_strip_thinking() {
  local content="$1"
  # Strip reasoning/thinking tags (e.g. <think>...</think>) if output by the model
  printf '%s\n' "$content" | sed -e '/<think>/,/<\/think>/d'
}

shunt_invoke_payload() {
  local payload_file="$1"
  shunt_tmpfile response_file || return 1
  shunt_tmpfile stderr_file || return 1

  # Security: validate endpoint before sending any data
  shunt_validate_endpoint "$SHUNT_ENDPOINT" || return 1

  local auth_args=()
  if [ -n "${SHUNT_API_KEY:-}" ]; then
    local auth_cfg
    if shunt_auth_config_file auth_cfg; then
      auth_args=(--config "$auth_cfg")
    fi
  fi

  curl -s -S \
    --max-time "$SHUNT_TIMEOUT_SECONDS" \
    -X POST "$SHUNT_ENDPOINT" \
    -H "Content-Type: application/json" \
    "${auth_args[@]}" \
    --data-binary @"$payload_file" \
    > "$response_file" 2>"$stderr_file"
  local rc=$?
  local err
  err=$(cat "$stderr_file")

  if [ "$rc" -ne 0 ]; then
    if [[ "$err" =~ "Operation timed out" || "$err" =~ "timed out" || "$rc" -eq 28 ]]; then
      echo "Error: local LLM request timed out after ${SHUNT_TIMEOUT_SECONDS}s at $SHUNT_ENDPOINT" >&2
      echo "Raise SHUNT_TIMEOUT_SECONDS or check your local inference server." >&2
    elif [[ "$err" =~ "Failed to connect" || "$err" =~ "Connection refused" || "$rc" -eq 7 ]]; then
      echo "Error: could not connect to local LLM server at $SHUNT_ENDPOINT" >&2
      echo "Ensure llama-server / Ollama / vLLM is running on the configured port." >&2
    else
      echo "Error: HTTP request failed (curl exit code $rc): $err" >&2
    fi
    return 1
  fi

  local response
  response=$(cat "$response_file")

  if ! printf '%s' "$response" | jq -e . >/dev/null 2>&1; then
    shunt_report_error "Local LLM endpoint returned unparseable output" "$response"
    return 1
  fi

  local err_msg
  err_msg=$(printf '%s' "$response" | jq -r '.error.message // .error // empty' 2>/dev/null)
  if [ -n "$err_msg" ]; then
    shunt_report_error "Local LLM error" "$response"
    return 1
  fi

  local text
  text=$(printf '%s' "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
  if [ -z "$text" ]; then
    shunt_report_error "Local LLM returned empty message content" "$response"
    return 1
  fi

  text=$(shunt_strip_thinking "$text")
  printf '%s\n' "$text"
}

shunt_invoke() {
  local mode_name="$1" message_file="$2"
  local system_prompt=""

  if [ "$mode_name" = "bulk-reader" ]; then
    system_prompt="You are a precise code analyst. Read the provided files and answer the question concisely. Output structured bullets only. No greetings, no prose, no preambles, no summaries. Lead every bullet with the exact name, type, or line number. Use nested bullets for details. Skip anything the caller did not ask for."
  elif [ "$mode_name" = "code-writer" ]; then
    system_prompt="You generate code files based on a spec and reference files. Match the existing patterns, conventions, naming, and style exactly. Output only the code — no explanations, no markdown fences unless asked. If the spec is ambiguous, make reasonable choices that match the patterns in the reference code."
  else
    system_prompt="You are an expert coding assistant. Respond accurately and concisely."
  fi

  shunt_tmpfile payload_file || return 1

  jq -n \
    --arg model "$SHUNT_MODEL" \
    --arg sys "$system_prompt" \
    --rawfile user "$message_file" \
    --argjson temp "$SHUNT_TEMPERATURE" \
    '{
      model: $model,
      temperature: $temp,
      messages: [
        {role: "system", content: $sys},
        {role: "user", content: $user}
      ],
      stream: false
    }' > "$payload_file"

  shunt_invoke_payload "$payload_file"
}

shunt_invoke_messages() {
  local messages_file="$1"
  shunt_tmpfile payload_file || return 1

  jq -n \
    --arg model "$SHUNT_MODEL" \
    --slurpfile msgs "$messages_file" \
    --argjson temp "$SHUNT_TEMPERATURE" \
    '{
      model: $model,
      temperature: $temp,
      messages: $msgs[0],
      stream: false
    }' > "$payload_file"

  shunt_invoke_payload "$payload_file"
}
