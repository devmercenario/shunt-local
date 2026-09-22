#!/bin/bash
# Apply-mode evals: task-exec/code-write must not write without approval.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

echo "Apply-Mode Evals"
echo "────────────────────────────────────────────────────────────────"

mkdir -p "$WORKDIR/bin" "$WORKDIR/home" "$WORKDIR/work"
cat > "$WORKDIR/bin/curl" <<'MOCK'
#!/bin/bash
if [[ "$*" == *"/v1/models"* ]]; then echo '{"data": []}'; exit 0; fi
printf '%s' '{"choices":[{"message":{"role":"assistant","content":"```out.py\nprint(1)\n```"}}]}'
MOCK
chmod +x "$WORKDIR/bin/curl"

run_task_exec() { # extra args...
  ( cd "$WORKDIR/work" && HOME="$WORKDIR/home" SHUNT_MOCK_ONLINE=1 SHUNT_SANDBOX=none \
      PATH="$WORKDIR/bin:$PATH" "$PLUGIN_DIR/scripts/task-exec" \
      --instruction noop --files "$WORKDIR/work/out.py" "$@" </dev/null 2>/dev/null )
}

rm -f "$WORKDIR/work/out.py"
status=$(run_task_exec | jq -r '.status')
check "confirm-status" "needs_confirmation" "$status" "non-interactive run without --yes asks for confirmation"
check "confirm-no-write" "absent" "$([ -f "$WORKDIR/work/out.py" ] && echo present || echo absent)" "no file written without approval"

rm -f "$WORKDIR/work/out.py"
out=$(run_task_exec --dry-run)
check "dry-run-status" "dry_run" "$(printf '%s' "$out" | jq -r '.status')" "--dry-run returns a dry-run payload"
check "dry-run-no-write" "absent" "$([ -f "$WORKDIR/work/out.py" ] && echo present || echo absent)" "--dry-run writes nothing"
check "dry-run-diff" "true" "$(printf '%s' "$out" | jq -r '.proposed | length > 0' 2>/dev/null)" "--dry-run proposes changes"

rm -f "$WORKDIR/work/out.py"
status=$(run_task_exec --yes | jq -r '.status')
check "yes-status" "success" "$status" "--yes approves the plan"
check "yes-writes" "present" "$([ -f "$WORKDIR/work/out.py" ] && echo present || echo absent)" "--yes writes the file"

# code-write gates
run_code_write() {
  ( cd "$WORKDIR/work" && HOME="$WORKDIR/home" \
      PATH="$WORKDIR/bin:$PATH" "$PLUGIN_DIR/scripts/code-write" \
      --spec x --reference "$WORKDIR/work/out.py" --target "$WORKDIR/work/gen.py" "$@" </dev/null 2>/dev/null )
}
rm -f "$WORKDIR/work/gen.py"
run_code_write >/dev/null
check "cw-confirm-no-write" "absent" "$([ -f "$WORKDIR/work/gen.py" ] && echo present || echo absent)" "code-write does not write without approval"
rm -f "$WORKDIR/work/gen.py"
run_code_write --dry-run >/dev/null
check "cw-dry-run-no-write" "absent" "$([ -f "$WORKDIR/work/gen.py" ] && echo present || echo absent)" "code-write --dry-run writes nothing"
rm -f "$WORKDIR/work/gen.py"
run_code_write --yes >/dev/null
check "cw-yes-writes" "present" "$([ -f "$WORKDIR/work/gen.py" ] && echo present || echo absent)" "code-write --yes writes the file"

echo ""
echo "## $PASSED $FAILED"
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
