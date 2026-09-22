#!/bin/bash
# HTTP transport to the local OpenAI-compatible endpoint. Sourced by local-llm.sh.

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
  curl -s -S --connect-timeout 0.1 -m 0.3 ${auth_args[@]+"${auth_args[@]}"} "$health_url" >/dev/null 2>&1
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
    ${auth_args[@]+"${auth_args[@]}"} \
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

  # Redact secrets before anything leaves the machine.
  local user_file="$message_file"
  if [ "${SHUNT_REDACT_SECRETS:-true}" = "true" ]; then
    local redacted_file
    shunt_tmpfile redacted_file || return 1
    shunt_redact_file "$message_file" "$redacted_file" || return 1
    user_file="$redacted_file"
  fi

  jq -n \
    --arg model "$SHUNT_MODEL" \
    --arg sys "$system_prompt" \
    --rawfile user "$user_file" \
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

  local msgs_file="$messages_file"
  if [ "${SHUNT_REDACT_SECRETS:-true}" = "true" ]; then
    local redacted_msgs
    shunt_tmpfile redacted_msgs || return 1
    shunt_redact_file "$messages_file" "$redacted_msgs" || return 1
    msgs_file="$redacted_msgs"
  fi

  jq -n \
    --arg model "$SHUNT_MODEL" \
    --slurpfile msgs "$msgs_file" \
    --argjson temp "$SHUNT_TEMPERATURE" \
    '{
      model: $model,
      temperature: $temp,
      messages: $msgs[0],
      stream: false
    }' > "$payload_file"

  shunt_invoke_payload "$payload_file"
}
