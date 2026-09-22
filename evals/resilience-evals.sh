#!/bin/bash
# Resilience and multi-plugin non-interference evals.
#
# Validates:
#   1. All Python scripts compile cleanly (python3 -m py_compile).
#   2. shunt_guard.py fails open (exit 0) on internal exceptions or corrupted input,
#      ensuring it NEVER blocks the host harness or breaks other plugins (ai-memory, rtk).
#   3. Antigravity write confinement respects workspace repository root when hook runs from ~/.gemini.
#   4. Installer and uninstaller preserve other plugins' hooks (e.g. ai-memory).

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
    printf "  \033[32mPASS\033[0m  %-32s %s\n" "$name" "$desc"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-32s expected=[%s] got=[%s]\n" "$name" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

echo "Resilience & Interoperability Evals"
echo "────────────────────────────────────────────────────────────────"

# 1. Python compilation check: all python sources must compile.
py_errors=0
for py_file in "$PLUGIN_DIR"/hooks/*.py "$PLUGIN_DIR"/evals/*.py; do
  [ -f "$py_file" ] || continue
  if ! "$PY" -m py_compile "$py_file" 2>/dev/null; then
    py_errors=$((py_errors + 1))
  fi
done
check "py-compile-all" "0" "$py_errors" "all python files compile without syntax errors"

# 2. Fail-open behavior: shunt_guard.py must exit 0 and allow when encountering an internal runtime error.
set +e
crash_out=$(printf '{"toolCall":{"name":"run_command","args":{"CommandLine":"ls"}}}' | \
  __SHUNT_TEST_FORCE_CRASH=1 "$PY" "$GUARD" --harness antigravity 2>/dev/null)
crash_rc=$?
set -e
check "guard-crash-exit-code" "0" "$crash_rc" "guard exits 0 on internal error (fail-open)"
crash_decision=$(printf '%s' "$crash_out" | jq -r '.decision // empty' 2>/dev/null || true)
check "guard-crash-antigravity" "allow" "$crash_decision" "guard emits allow decision on internal error"

# 3. Antigravity daemon CWD: writes in repository must NOT be blocked when daemon runs in ~/.gemini.
daemon_dir="$WORKDIR/daemon"
mkdir -p "$daemon_dir"
set +e
agy_write_out=$(cd "$daemon_dir" && printf '{"toolCall":{"name":"write_to_file","args":{"TargetFile":"%s/evals/test_dummy.txt"}}}' "$PLUGIN_DIR" | \
  "$PY" "$GUARD" --harness antigravity --kind write 2>/dev/null)
set -e
agy_decision=$(printf '%s' "$agy_write_out" | jq -r '.decision // empty' 2>/dev/null || true)
check "guard-antigravity-workspace-write" "allow" "$agy_decision" "Antigravity daemon cwd allows workspace writes"

# 4. Corrupted / garbage input: must exit 0 and allow.
set +e
garbage_out=$(printf 'NOT_VALID_JSON{{{<<<' | "$PY" "$GUARD" --harness antigravity 2>/dev/null)
garbage_rc=$?
set -e
check "guard-garbage-exit-code" "0" "$garbage_rc" "guard exits 0 on invalid json input"
garbage_decision=$(printf '%s' "$garbage_out" | jq -r '.decision // empty' 2>/dev/null || true)
check "guard-garbage-allow" "allow" "$garbage_decision" "guard emits allow on invalid json input"

# 5. Multi-plugin coexistence: install.sh and uninstall.sh must preserve ai-memory hooks.
HOME_DIR="$WORKDIR/home"
mkdir -p "$HOME_DIR/.gemini/config" "$WORKDIR/bin"
for c in agy claude opencode cursor; do
  printf '#!/bin/sh\nexit 0\n' > "$WORKDIR/bin/$c"
  chmod +x "$WORKDIR/bin/$c"
done

# Pre-populate hooks.json with ai-memory configuration.
cat <<'HOOKS_EOF' > "$HOME_DIR/.gemini/config/hooks.json"
{
  "ai-memory": {
    "PreToolUse": [
      {"matcher": ".*", "hooks": [{"type": "command", "command": "ai-memory-hook"}]}
    ],
    "PostToolUse": [
      {"matcher": ".*", "hooks": [{"type": "command", "command": "ai-memory-post-hook"}]}
    ]
  }
}
HOOKS_EOF

# Run install.sh.
HOME="$HOME_DIR" SHUNT_NO_PULL=1 PATH="$WORKDIR/bin:$PATH" bash "$PLUGIN_DIR/install.sh" >/dev/null 2>&1
GEMINI_HOOKS="$HOME_DIR/.gemini/config/hooks.json"

check "preserve-ai-memory-pre" "ai-memory-hook" \
  "$(jq -r '."ai-memory".PreToolUse[0].hooks[0].command // empty' "$GEMINI_HOOKS")" \
  "install.sh preserves existing ai-memory PreToolUse hooks"

check "preserve-ai-memory-post" "ai-memory-post-hook" \
  "$(jq -r '."ai-memory".PostToolUse[0].hooks[0].command // empty' "$GEMINI_HOOKS")" \
  "install.sh preserves existing ai-memory PostToolUse hooks"

check "has-shunt-local-hooks" "yes" \
  "$([ "$(jq -r '."shunt-local".PreToolUse | length' "$GEMINI_HOOKS")" -gt 0 ] && echo yes || echo no)" \
  "install.sh registers shunt-local hooks alongside ai-memory"

# Run uninstall.sh.
HOME="$HOME_DIR" PATH="$WORKDIR/bin:$PATH" bash "$PLUGIN_DIR/uninstall.sh" >/dev/null 2>&1

check "uninstall-keeps-ai-memory" "ai-memory-hook" \
  "$(jq -r '."ai-memory".PreToolUse[0].hooks[0].command // empty' "$GEMINI_HOOKS")" \
  "uninstall.sh leaves ai-memory hooks untouched"

check "uninstall-removes-shunt" "null" \
  "$(jq -r '."shunt-local" // "null"' "$GEMINI_HOOKS")" \
  "uninstall.sh removes shunt-local hooks"

echo ""
echo "## $PASSED $FAILED"
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
