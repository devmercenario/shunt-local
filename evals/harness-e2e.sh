#!/bin/bash
# Harness end-to-end smoke checks.
#
# When a harness CLI is installed, invoke it and verify the registration
# artifact. Absent harnesses are skipped so CI stays green. This is a shallow
# smoke test (no agent session is driven) intended to catch a broken install on
# a machine that actually has the harness.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

echo "Harness E2E Evals"
echo "────────────────────────────────────────────────────────────────"

smoke() { # name, cli, version-arg, registration-check (optional)
  local name="$1" cli="$2" varg="$3" reg="${4:-}"
  if ! command -v "$cli" >/dev/null 2>&1; then
    printf "  \033[33mSKIP\033[0m  %-28s %s not installed\n" "$name" "$cli"
    return 0
  fi
  local rc=0
  "$cli" "$varg" >/dev/null 2>&1 || rc=$?
  check "$name-cli" "0" "$rc" "$cli $varg runs"
  if [ -n "$reg" ]; then
    check "$name-registration" "yes" "$([ -e "$reg" ] && echo yes || echo no)" "$cli registration artifact present"
  fi
}

smoke opencode opencode --version "$HOME/.config/opencode/plugins/shunt-local.ts"
smoke claude claude --version ""
smoke codex codex --version ""
smoke agy agy --help ""

echo ""
echo "## $PASSED $FAILED"
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
