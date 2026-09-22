#!/bin/bash
# Library-structure evals: local-llm.sh is a loader over the modules, and the
# modules together expose the full public function surface.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$PLUGIN_DIR/scripts/lib/local-llm.sh"

WORKDIR="$(mktemp -d)"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/home"

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

echo "Library Evals"
echo "────────────────────────────────────────────────────────────────"

# 1. Every module exists and parses.
missing=""
for m in common config validate sandbox audit http hooks; do
  [ -f "$PLUGIN_DIR/scripts/lib/$m.sh" ] || missing="$missing $m"
done
check "modules-present" "" "$missing" "all library modules exist"

syntax_ok=yes
for f in "$PLUGIN_DIR"/scripts/lib/*.sh; do
  bash -n "$f" 2>/dev/null || syntax_ok=no
done
check "modules-parse" "yes" "$syntax_ok" "all modules pass bash -n"

# 2. The loader exposes the full public surface.
funcs=$(HOME="$WORKDIR/home" bash -c '
  . "'"$LIB"'" >/dev/null 2>&1
  for f in shunt_load_config shunt_validate_endpoint shunt_is_enabled shunt_hook_is_enabled \
           shunt_validate_exec_command shunt_run_simple_command \
           shunt_sandbox_probe shunt_sandbox_backend shunt_sandbox_wrap shunt_run_command \
           shunt_audit shunt_auth_config_file shunt_is_online shunt_report_error \
           shunt_strip_thinking shunt_invoke_payload shunt_invoke shunt_invoke_messages \
           shunt_emit_pretooluse_decision shunt_trim shunt_list_contains \
           shunt_is_sensitive_name shunt_path_sensitive shunt_to_native shunt_to_posix \
           shunt_realpath shunt_read_allowed shunt_redact_file shunt_tmpfile shunt_preflight; do
    declare -F "$f" >/dev/null || echo "MISSING:$f"
  done
' 2>/dev/null)
check "public-surface" "" "$funcs" "loader exposes every public function"

# 3. SHUNT_LIB_DIR points at the library directory.
libdir=$(HOME="$WORKDIR/home" bash -c ". '$LIB' >/dev/null 2>&1; printf '%s' \"\$SHUNT_LIB_DIR\"" 2>/dev/null)
check "lib-dir" "$PLUGIN_DIR/scripts/lib" "$libdir" "SHUNT_LIB_DIR is the lib directory"

echo ""
echo "## $PASSED $FAILED"
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
