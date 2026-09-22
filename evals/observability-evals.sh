#!/bin/bash
# Observability evals: the audit log records delegated operations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKDIR="$(mktemp -d)"
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

echo "Observability Evals"
echo "────────────────────────────────────────────────────────────────"

mkdir -p "$WORKDIR/bin" "$WORKDIR/home" "$WORKDIR/work"
cd "$WORKDIR/work"
cat > "$WORKDIR/bin/curl" <<'MOCK'
#!/bin/bash
if [[ "$*" == *"/v1/models"* ]]; then echo '{"data": []}'; exit 0; fi
printf '%s' '{"choices":[{"message":{"role":"assistant","content":"```out.py\nprint(1)\n```"}}]}'
MOCK
chmod +x "$WORKDIR/bin/curl"

AUDIT="$WORKDIR/audit.log"
: > "$AUDIT"
( cd "$WORKDIR/work" && HOME="$WORKDIR/home" SHUNT_MOCK_ONLINE=1 SHUNT_SANDBOX=none \
    SHUNT_AUDIT_LOG="$AUDIT" PATH="$WORKDIR/bin:$PATH" \
    "$PLUGIN_DIR/scripts/task-exec" --instruction noop --files "$WORKDIR/work/out.py" --yes \
    </dev/null >/dev/null 2>&1 ) || true
check "audit-task-exec" "success" "$(jq -r 'select(.tool=="task-exec") | .status' "$AUDIT" 2>/dev/null | tail -1)" "task-exec appends an audit record"
check "audit-sandbox-field" "yes" "$(jq -r 'select(.tool=="task-exec") | has("sandbox")' "$AUDIT" 2>/dev/null | tail -1 | grep -q true && echo yes || echo no)" "audit record carries the sandbox backend"

( cd "$WORKDIR/work" && HOME="$WORKDIR/home" SHUNT_AUDIT_LOG="$AUDIT" \
    PATH="$WORKDIR/bin:$PATH" "$PLUGIN_DIR/scripts/code-write" --spec x \
    --reference "$WORKDIR/work/out.py" --target "$WORKDIR/work/gen.py" --yes \
    </dev/null >/dev/null 2>&1 ) || true
check "audit-code-write" "written" "$(jq -r 'select(.tool=="code-write") | .status' "$AUDIT" 2>/dev/null | tail -1)" "code-write appends an audit record"

if [ -f "$AUDIT" ]; then
  mode=$(stat -c '%a' "$AUDIT" 2>/dev/null || stat -f '%Lp' "$AUDIT" 2>/dev/null || echo "")
  check "audit-perms" "600" "$mode" "audit log is 0600"
else
  check "audit-perms" "600" "missing" "audit log is 0600"
fi

echo ""
echo "## $PASSED $FAILED"
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
