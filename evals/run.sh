#!/bin/bash
# Master test runner for shunt-local: hook routing, config parsing, and transport evals.
#
# Usage:
#   bash evals/run.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$SCRIPT_DIR/.fixtures"
PASSED=0
FAILED=0
TOTAL=0

generate_fixture() {
  local path="$1" lines="$2"
  if [ "$lines" -eq 0 ]; then
    touch "$path"
  else
    seq 1 "$lines" | awk '{print "line "NR}' > "$path"
  fi
}

setup_fixtures() {
  local evals_file="$1"
  rm -rf "$FIXTURES"
  mkdir -p "$FIXTURES"

  local count
  count=$(jq '.evals | length' "$evals_file")

  for ((i = 0; i < count; i++)); do
    local fixture
    fixture=$(jq -r ".evals[$i].fixture" "$evals_file")
    [ "$fixture" = "null" ] && continue

    local lines
    lines=$(jq -r ".evals[$i].fixture.lines" "$evals_file")

    local input_path
    input_path=$(jq -r ".evals[$i].input.tool_input.file_path // empty" "$evals_file")
    if [ -z "$input_path" ]; then
      input_path=$(jq -r ".evals[$i].input.tool_input.command // empty" "$evals_file" | sed -E 's/^(cat|head|tail|less|more) +(-[^ ]+ +)*//' | sed 's/ .*//' | tr -d '"'"'")
    fi
    input_path=$(echo "$input_path" | sed "s|{{FIXTURES}}|$FIXTURES|")

    case "$input_path" in
      "$FIXTURES"/*) generate_fixture "$input_path" "$lines" ;;
    esac
  done
}

run_eval() {
  local hook="$1" name="$2" input="$3" expected="$4" reason="$5" env_json="$6"
  TOTAL=$((TOTAL + 1))

  local result actual
  if [ -n "$env_json" ] && [ "$env_json" != "null" ]; then
    local env_cmd=""
    while IFS='=' read -r key val; do
      env_cmd="$env_cmd $key=$val"
    done < <(echo "$env_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
    result=$(echo "$input" | env $env_cmd bash "$hook" 2>/dev/null)
  else
    result=$(echo "$input" | bash "$hook" 2>/dev/null)
  fi
  actual=$(echo "$result" | jq -r '.decision')

  if [ "$actual" = "$expected" ]; then
    printf "  \033[32mPASS\033[0m  %-30s %s\n" "$name" "$reason"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-30s expected=%s got=%s\n" "$name" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

run_suite() {
  local hook="$1" evals_file="$2" label="$3"

  setup_fixtures "$evals_file"

  echo ""
  echo "$label"
  echo "────────────────────────────────────────────────────────────────"

  local count
  count=$(jq '.evals | length' "$evals_file")

  for ((i = 0; i < count; i++)); do
    local name expected reason input
    name=$(jq -r ".evals[$i].name" "$evals_file")
    expected=$(jq -r ".evals[$i].expected_decision" "$evals_file")
    reason=$(jq -r ".evals[$i].reason" "$evals_file")
    input=$(jq -c ".evals[$i].input" "$evals_file" | sed "s|{{FIXTURES}}|$FIXTURES|g")

    local env_json
    env_json=$(jq -r ".evals[$i].env // empty" "$evals_file")
    run_eval "$hook" "$name" "$input" "$expected" "$reason" "$env_json"
  done

  rm -rf "$FIXTURES"
}

run_external_suite() {
  local script="$1" label="$2"
  echo ""
  echo "$label"
  echo "────────────────────────────────────────────────────────────────"

  local output counts p f
  output=$(bash "$script" 2>&1) || true

  printf '%s\n' "$output" | grep -v '^## ' || true
  counts=$(printf '%s\n' "$output" | grep '^## ' | tail -1 || true)
  p=$(printf '%s' "$counts" | awk '{print $2}')
  f=$(printf '%s' "$counts" | awk '{print $3}')

  if [ -z "$p" ]; then
    printf "  \033[31mFAIL\033[0m  %-32s suite did not report results\n" "$label"
    FAILED=$((FAILED + 1))
    TOTAL=$((TOTAL + 1))
    return
  fi

  PASSED=$((PASSED + p))
  FAILED=$((FAILED + f))
  TOTAL=$((TOTAL + p + f))
}

run_suite "$PLUGIN_DIR/hooks/check-file-size" "$SCRIPT_DIR/hook-evals.json" "Read hook (check-file-size)"
run_suite "$PLUGIN_DIR/hooks/check-bash-read" "$SCRIPT_DIR/bash-hook-evals.json" "Bash hook (check-bash-read)"
run_external_suite "$SCRIPT_DIR/config-evals.sh" "Config suite (shunt.config.json & env overrides)"
run_external_suite "$SCRIPT_DIR/transport-evals.sh" "Transport suite (scripts/lib/local-llm.sh against mocked HTTP)"

echo ""
echo "════════════════════════════════════════════════════════════════"
printf "Total: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m, %d total\n" "$PASSED" "$FAILED" "$TOTAL"
echo ""

[ "$FAILED" -gt 0 ] && exit 1
exit 0
