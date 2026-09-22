#!/bin/bash
# Configuration loading, endpoint validation and enable/disable helpers.
# Sourced by local-llm.sh (do not execute directly).

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

  # Secret resolution: prefer an explicit key, then a command (e.g. a keyring
  # lookup), then a file. SHUNT_API_KEY_CMD is operator-controlled (like
  # SHUNT_ALLOW_UNSAFE) and must never be set from untrusted input.
  if [ -z "$SHUNT_API_KEY" ] && [ -n "${SHUNT_API_KEY_CMD:-}" ]; then
    SHUNT_API_KEY=$(eval "$SHUNT_API_KEY_CMD" 2>/dev/null || true)
  fi
  if [ -z "$SHUNT_API_KEY" ] && [ -n "${SHUNT_API_KEY_FILE:-}" ] && [ -r "${SHUNT_API_KEY_FILE}" ]; then
    SHUNT_API_KEY=$(cat -- "${SHUNT_API_KEY_FILE}" 2>/dev/null || true)
  fi
}

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
