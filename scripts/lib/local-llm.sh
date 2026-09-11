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
  elif [ -f "./shunt.config.json" ]; then
    cfg_file="./shunt.config.json"
  elif [ -f "$HOME/.config/shunt-local/config.json" ]; then
    cfg_file="$HOME/.config/shunt-local/config.json"
  fi

  if [ -n "$cfg_file" ] && command -v jq >/dev/null 2>&1; then
    local cfg_endpoint cfg_model cfg_temp cfg_timeout cfg_key cfg_min_lines
    cfg_endpoint=$(jq -r '.endpoint // empty' "$cfg_file" 2>/dev/null)
    cfg_model=$(jq -r '.model // empty' "$cfg_file" 2>/dev/null)
    cfg_temp=$(jq -r '.temperature // empty' "$cfg_file" 2>/dev/null)
    cfg_timeout=$(jq -r '.timeout_seconds // empty' "$cfg_file" 2>/dev/null)
    cfg_key=$(jq -r '.api_key // empty' "$cfg_file" 2>/dev/null)
    cfg_min_lines=$(jq -r '.min_lines // empty' "$cfg_file" 2>/dev/null)

    [ -z "${SHUNT_ENDPOINT:-}" ] && [ -n "$cfg_endpoint" ] && SHUNT_ENDPOINT="$cfg_endpoint"
    [ -z "${SHUNT_MODEL:-}" ] && [ -n "$cfg_model" ] && SHUNT_MODEL="$cfg_model"
    [ -z "${SHUNT_TEMPERATURE:-}" ] && [ -n "$cfg_temp" ] && SHUNT_TEMPERATURE="$cfg_temp"
    [ -z "${SHUNT_TIMEOUT_SECONDS:-}" ] && [ -n "$cfg_timeout" ] && SHUNT_TIMEOUT_SECONDS="$cfg_timeout"
    [ -z "${SHUNT_API_KEY:-}" ] && [ -n "$cfg_key" ] && SHUNT_API_KEY="$cfg_key"
    [ -z "${SHUNT_MIN_LINES:-}" ] && [ -n "$cfg_min_lines" ] && SHUNT_MIN_LINES="$cfg_min_lines"
  fi

  SHUNT_ENDPOINT="${SHUNT_ENDPOINT:-$DEFAULT_ENDPOINT}"
  SHUNT_MODEL="${SHUNT_MODEL:-$DEFAULT_MODEL}"
  SHUNT_TEMPERATURE="${SHUNT_TEMPERATURE:-$DEFAULT_TEMPERATURE}"
  SHUNT_TIMEOUT_SECONDS="${SHUNT_TIMEOUT_SECONDS:-$DEFAULT_TIMEOUT_SECONDS}"
  SHUNT_MIN_LINES="${SHUNT_MIN_LINES:-$DEFAULT_MIN_LINES}"
  SHUNT_API_KEY="${SHUNT_API_KEY:-}"
}

shunt_load_config

# Temporary file management with automatic cleanup on exit
SHUNT_TMPFILES=()
shunt_tmpfile() {
  local f
  f=$(mktemp) || return 1
  SHUNT_TMPFILES+=("$f")
  trap 'rm -f "${SHUNT_TMPFILES[@]}"' EXIT INT TERM
  printf -v "$1" '%s' "$f"
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
  echo "$content" | sed -e '/<think>/,/<\/think>/d'
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
  shunt_tmpfile response_file || return 1
  shunt_tmpfile stderr_file || return 1

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

  local auth_header=()
  if [ -n "$SHUNT_API_KEY" ]; then
    auth_header=(-H "Authorization: Bearer $SHUNT_API_KEY")
  fi

  curl -s -S \
    --max-time "$SHUNT_TIMEOUT_SECONDS" \
    -X POST "$SHUNT_ENDPOINT" \
    -H "Content-Type: application/json" \
    "${auth_header[@]}" \
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
