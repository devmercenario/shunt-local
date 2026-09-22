#!/bin/bash
# RTK interoperability evals.
#
# Documents two facts:
#   1. shunt-local has no coupling to rtk (its tools never call rtk).
#   2. rtk rewrites `cat` to `rtk read`, which the shunt-local bash gate does not
#      match — i.e. with rtk installed the bash read gate is shadowed.
#
# rtk-specific assertions run only when rtk is on PATH; the gate/shadowing
# checks always run.

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

echo "RTK Interop Evals"
echo "────────────────────────────────────────────────────────────────"

gate() { # command -> allow|deny
  local payload="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$1\"}}"
  local out
  out=$(printf '%s' "$payload" | HOME="$WORKDIR/home" __SHUNT_TEST_MOCK_ONLINE=1 "$PY" "$GUARD" --kind bash 2>/dev/null)
  if [ -z "$out" ]; then echo allow; else echo "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"')"; fi
}

# 1. No coupling: shunt-local never references rtk.
coupling=$(grep -rl --include='*.sh' --include='*.py' --include='*.ts' 'rtk' \
  "$PLUGIN_DIR/scripts" "$PLUGIN_DIR/hooks" "$PLUGIN_DIR/plugins" 2>/dev/null | head -1 || true)
check "no-rtk-coupling" "" "$coupling" "shunt-local sources never call rtk"

# 2. Shadowing: the bash gate matches `cat` but not `rtk read`.
check "gate-blocks-cat" "deny" "$(gate "cat $WORKDIR/large.txt")" "bash gate blocks a large cat"
check "gate-misses-rtk-read" "allow" "$(gate "rtk read $WORKDIR/large.txt")" "bash gate does not match rtk read (shadowed)"

if command -v rtk >/dev/null 2>&1; then
  rewritten=$(rtk rewrite "cat $WORKDIR/large.txt" 2>/dev/null || true)
  check "rtk-rewrites-cat" "yes" \
    "$(printf '%s' "$rewritten" | grep -q '^rtk read' && echo yes || echo no)" "rtk rewrites cat to 'rtk read'"

  # rtk prints nothing when it does not rewrite a command.
  check "rtk-leaves-bulk-read" "" "$(rtk rewrite "bulk-read --paths $WORKDIR/large.txt --question q" 2>/dev/null || true)" "rtk does not rewrite bulk-read"

  check "rtk-leaves-exec" "" "$(rtk rewrite "shunt-local exec --instruction x --files a.py --test-cmd npm" 2>/dev/null || true)" "rtk does not rewrite shunt-local exec"
else
  printf "  \033[33mSKIP\033[0m  %-28s rtk not installed (rewrite checks skipped)\n" "rtk-specific"
fi

echo ""
echo "## $PASSED $FAILED"
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
