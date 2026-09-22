#!/bin/bash
# Contract evals: the exact decision schema each harness expects.
# These fail loudly if a harness adapter changes shape.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GUARD="$PLUGIN_DIR/hooks/shunt_guard.py"
PY="${PYTHON:-$(command -v python3 || command -v python)}"

WORKDIR="$(mktemp -d)"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/home"
seq 1 400 > "$WORKDIR/large.txt"

PASSED=0
FAILED=0
check() {
  local name="$1" expected="$2" actual="$3" desc="$4"
  if [ "$expected" = "$actual" ]; then
    printf "  \033[32mPASS\033[0m  %-28s %s\n" "$name" "$desc"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-28s expected=[%s] got=[%s]\n" "$name" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

echo "Contract Evals"
echo "────────────────────────────────────────────────────────────────"

run() { printf '%s' "$1" | HOME="$WORKDIR/home" __SHUNT_TEST_MOCK_ONLINE=1 "$PY" "$GUARD" "${@:2}" 2>/dev/null; }

claude_read="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$WORKDIR/large.txt\"}}"
claude_ok="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$WORKDIR/home/none.txt\"}}"

# Claude deny: only hookSpecificOutput with the three documented keys.
g=$(run "$claude_read")
check "claude-deny-keys" "hookSpecificOutput" "$(printf '%s' "$g" | jq -r 'keys | join(",")')" "top-level key is hookSpecificOutput"
check "claude-deny-inner" "hookEventName,permissionDecision,permissionDecisionReason" \
  "$(printf '%s' "$g" | jq -r '.hookSpecificOutput | keys | join(",")')" "exact PreToolUse deny schema"
check "claude-deny-event" "PreToolUse" "$(printf '%s' "$g" | jq -r '.hookSpecificOutput.hookEventName')" "hookEventName is PreToolUse"

# Claude allow is silent (no auto-approval).
check "claude-allow-empty" "" "$(run "$claude_ok")" "allow emits nothing"

# Antigravity.
agy="{\"toolCall\":{\"name\":\"view_file\",\"args\":{\"AbsolutePath\":\"$WORKDIR/large.txt\"}}}"
g=$(run "$agy" --harness antigravity)
check "agy-deny-keys" "decision,reason" "$(printf '%s' "$g" | jq -r 'keys | join(",")')" "Antigravity deny uses decision+reason"
g=$(run "{\"toolCall\":{\"name\":\"view_file\",\"args\":{\"AbsolutePath\":\"$WORKDIR/home/none.txt\"}}}" --harness antigravity)
check "agy-allow-keys" "decision" "$(printf '%s' "$g" | jq -r 'keys | join(",")')" "Antigravity allow uses decision only"

# Cursor.
g=$(run "{\"tool_name\":\"Shell\",\"tool_input\":{\"command\":\"cat $WORKDIR/large.txt\"}}" --harness cursor --kind bash)
check "cursor-deny-keys" "agent_message,permission,user_message" "$(printf '%s' "$g" | jq -r 'keys | join(",")')" "Cursor deny uses permission+user_message+agent_message"
g=$(run "{\"tool_name\":\"Shell\",\"tool_input\":{\"command\":\"cat $WORKDIR/home/none.txt\"}}" --harness cursor --kind bash)
check "cursor-allow-keys" "permission" "$(printf '%s' "$g" | jq -r 'keys | join(",")')" "Cursor allow uses permission only"

# additionalContext shape (Grep guidance).
g=$(run "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Grep\",\"tool_input\":{\"pattern\":\"x\",\"output_mode\":\"content\"}}" --kind grep)
check "context-keys" "additionalContext,hookEventName" \
  "$(printf '%s' "$g" | jq -r '.hookSpecificOutput | keys | join(",")')" "additionalContext pairs with hookEventName"

echo ""
echo "## $PASSED $FAILED"
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
