#!/bin/bash
# Test suite for configuration loading in scripts/lib/local-llm.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASSED=0
FAILED=0

check() {
  local name="$1" expected="$2" actual="$3" desc="$4"
  if [ "$expected" = "$actual" ]; then
    printf "  \033[32mPASS\033[0m  %-32s %s\n" "$name" "$desc"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-32s expected=[%s] got=[%s]\n" "$name" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

# Test 1: Default configuration when no file or env var is present
(
  unset SHUNT_ENDPOINT SHUNT_MODEL SHUNT_TEMPERATURE SHUNT_MIN_LINES SHUNT_TIMEOUT_SECONDS SHUNT_API_KEY SHUNT_CONFIG_PATH
  cd "$WORKDIR"
  . "$PLUGIN_DIR/scripts/lib/local-llm.sh"
  echo "$SHUNT_ENDPOINT|$SHUNT_MODEL|$SHUNT_TEMPERATURE|$SHUNT_MIN_LINES" > "$WORKDIR/res1"
)
IFS='|' read -r ep mod tmp lns < "$WORKDIR/res1"
check "default-endpoint" "http://127.0.0.1:8080/v1/chat/completions" "$ep" "fallback to default endpoint"
check "default-model" "Qwen/Qwen2.5-Coder-7B-Instruct-GGUF" "$mod" "fallback to default model"
check "default-temp" "0.2" "$tmp" "fallback to default temperature"
check "default-lines" "350" "$lns" "fallback to default min lines"

# Test 2: Loading from explicit SHUNT_CONFIG_PATH file
CUSTOM_CFG="$WORKDIR/custom-config.json"
cat << 'JSON' > "$CUSTOM_CFG"
{
  "endpoint": "http://localhost:11434/v1/chat/completions",
  "model": "qwen3.8-custom:9b",
  "temperature": 0.1,
  "min_lines": 250,
  "timeout_seconds": 60,
  "api_key": "custom-secret"
}
JSON
(
  unset SHUNT_ENDPOINT SHUNT_MODEL SHUNT_TEMPERATURE SHUNT_MIN_LINES SHUNT_TIMEOUT_SECONDS SHUNT_API_KEY
  export SHUNT_CONFIG_PATH="$CUSTOM_CFG"
  cd "$WORKDIR"
  . "$PLUGIN_DIR/scripts/lib/local-llm.sh"
  echo "$SHUNT_ENDPOINT|$SHUNT_MODEL|$SHUNT_TEMPERATURE|$SHUNT_MIN_LINES|$SHUNT_API_KEY" > "$WORKDIR/res2"
)
IFS='|' read -r ep mod tmp lns key < "$WORKDIR/res2"
check "custom-cfg-endpoint" "http://localhost:11434/v1/chat/completions" "$ep" "loads endpoint from custom file"
check "custom-cfg-model" "qwen3.8-custom:9b" "$mod" "loads model from custom file"
check "custom-cfg-temp" "0.1" "$tmp" "loads temperature from custom file"
check "custom-cfg-lines" "250" "$lns" "loads min_lines from custom file"
check "custom-cfg-key" "custom-secret" "$key" "loads api_key from custom file"

# Test 3: Environment variables take precedence over config file
CUSTOM_CFG="$WORKDIR/precedence-config.json"
cat << 'JSON' > "$CUSTOM_CFG"
{
  "endpoint": "http://file-endpoint:8080",
  "model": "file-model"
}
JSON
(
  export SHUNT_CONFIG_PATH="$CUSTOM_CFG"
  export SHUNT_ENDPOINT="http://env-endpoint:9090"
  export SHUNT_MODEL="env-model"
  cd "$WORKDIR"
  . "$PLUGIN_DIR/scripts/lib/local-llm.sh"
  echo "$SHUNT_ENDPOINT|$SHUNT_MODEL" > "$WORKDIR/res3"
)
IFS='|' read -r ep mod < "$WORKDIR/res3"
check "precedence-endpoint" "http://env-endpoint:9090" "$ep" "env var overrides config file endpoint"
check "precedence-model" "env-model" "$mod" "env var overrides config file model"

echo "## $PASSED $FAILED"
[ "$FAILED" -gt 0 ] && exit 1
exit 0
