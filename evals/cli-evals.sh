#!/bin/bash
# Management-CLI evals: on/off/hook/status/help and error handling.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PLUGIN_DIR/scripts/shunt-local"

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

run() { HOME="$WORKDIR/home" bash "$CLI" "$@" 2>&1; }
CONFIG="$WORKDIR/home/.config/shunt-local/config.json"
DISABLED="$WORKDIR/home/.config/shunt-local/disabled"

echo "CLI Evals"
echo "────────────────────────────────────────────────────────────────"

check "help" "yes" "$(run --help | grep -q 'Usage:' && echo yes || echo no)" "--help lists usage"
check "no-args" "yes" "$(run | grep -q 'Usage:' && echo yes || echo no)" "no args prints usage"

check "unknown-command" "1" "$(set +e; HOME="$WORKDIR/home" bash "$CLI" nonsense >/dev/null 2>&1; echo $?; set -e)" "unknown command exits 1"

# on creates config and clears the disabled marker.
HOME="$WORKDIR/home" bash "$CLI" on >/dev/null 2>&1
check "on-config" "yes" "$([ -f "$CONFIG" ] && echo yes || echo no)" "on creates config.json"
check "on-enabled" "true" "$(jq -r '.enabled' "$CONFIG")" "on sets enabled=true"
if command -v cygpath >/dev/null 2>&1; then
  check "on-perms" "skip" "skip" "config permissions are not meaningful on Windows"
else
  check "on-perms" "yes" "$(mode=$(stat -c '%a' "$CONFIG" 2>/dev/null || stat -f '%Lp' "$CONFIG"); [ "$mode" = "600" ] && echo yes || echo no)" "config is 0600"
fi

# off creates the disabled marker and flips enabled.
HOME="$WORKDIR/home" bash "$CLI" off >/dev/null 2>&1
check "off-disabled-file" "yes" "$([ -f "$DISABLED" ] && echo yes || echo no)" "off creates the disabled marker"
check "off-enabled" "false" "$(jq -r '.enabled' "$CONFIG")" "off sets enabled=false"

# hook toggles.
HOME="$WORKDIR/home" bash "$CLI" hook view_file off >/dev/null 2>&1
check "hook-off" "false" "$(jq -r '.hooks.view_file' "$CONFIG")" "hook view_file off persists"
HOME="$WORKDIR/home" bash "$CLI" hook run_command on >/dev/null 2>&1
check "hook-on" "true" "$(jq -r '.hooks.run_command' "$CONFIG")" "hook run_command on persists"
check "hook-unknown" "1" "$(set +e; HOME="$WORKDIR/home" bash "$CLI" hook nope on >/dev/null 2>&1; echo $?; set -e)" "unknown hook name exits 1"
check "hook-bad-action" "1" "$(set +e; HOME="$WORKDIR/home" bash "$CLI" hook view_file maybe >/dev/null 2>&1; echo $?; set -e)" "invalid hook action exits 1"

# status reflects state.
HOME="$WORKDIR/home" bash "$CLI" on >/dev/null 2>&1
out=$(run status)
check "status-enabled" "yes" "$(printf '%s' "$out" | grep -q 'ENABLED' && echo yes || echo no)" "status shows the master switch"
check "status-subhook" "yes" "$(printf '%s' "$out" | grep -q 'view_file' && echo yes || echo no)" "status shows sub-hooks"

echo ""
echo "## $PASSED $FAILED"
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
