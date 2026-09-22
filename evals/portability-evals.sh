#!/bin/bash
# Portability evals: Windows-style paths, PowerShell tool, CRLF, interpreter
# resolution and the PowerShell installer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GUARD="$PLUGIN_DIR/hooks/shunt_guard.py"
PY="${PYTHON:-$(command -v python3 || command -v python)}"

WORKDIR="$(mktemp -d)"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
trap 'rm -rf "$WORKDIR"' EXIT

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

echo "Portability Evals"
echo "────────────────────────────────────────────────────────────────"

mkdir -p "$WORKDIR/home"
seq 1 400 > "$WORKDIR/large.txt"

guard() { printf '%s' "$1" | HOME="$WORKDIR/home" __SHUNT_TEST_MOCK_ONLINE=1 "$PY" "$GUARD" "${@:2}" 2>/dev/null; }

# Windows-style backslash paths must still be recognised as sensitive.
g=$(guard "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"C:\\\\proj\\\\.env\"}}" --kind write)
check "win-path-write" "deny" "$(printf '%s' "$g" | jq -r '.hookSpecificOutput.permissionDecision // empty')" "backslash .env path denied on write"
g=$(guard "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"C:\\\\proj\\\\app\\\\.git\\\\config\"}}")
check "win-path-read" "deny" "$(printf '%s' "$g" | jq -r '.hookSpecificOutput.permissionDecision // empty')" "backslash .git path denied on read"

# PowerShell is treated as a shell tool.
g=$(guard "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"PowerShell\",\"tool_input\":{\"command\":\"cat $WORKDIR/large.txt\"}}")
check "powershell-kind" "deny" "$(printf '%s' "$g" | jq -r '.hookSpecificOutput.permissionDecision // empty')" "PowerShell command routed to the shell gate"

# CRLF content must be counted.
payload=$(python3 -c "import json; print(json.dumps({'file_path':'$WORKDIR/win.txt','content':'x\r\n'*400}))")
g=$(guard "$payload" --harness cursor --kind read)
check "crlf-content" "deny" "$(printf '%s' "$g" | jq -r '.permission // empty')" "CRLF content over threshold is denied"

# Interpreter resolution in the bash wrappers.
check "wrapper-python-fallback" "yes" \
  "$(grep -q 'command -v python3 || command -v python' "$PLUGIN_DIR/hooks/check-file-size" && echo yes || echo no)" \
  "bash wrapper resolves python3 or python"

# PowerShell installer exists.
check "install-ps1" "yes" "$([ -f "$PLUGIN_DIR/install.ps1" ] && echo yes || echo no)" "install.ps1 is present"

echo ""
echo "## $PASSED $FAILED"
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
