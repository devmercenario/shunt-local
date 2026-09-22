#!/bin/bash
# Stats evals: `shunt-local stats` summarizes the audit log.

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

echo "Stats Evals"
echo "────────────────────────────────────────────────────────────────"

LOG="$WORKDIR/audit.log"

# Empty log.
out=$(HOME="$WORKDIR/home" SHUNT_AUDIT_LOG="$LOG" bash "$PLUGIN_DIR/scripts/shunt-local" stats --json)
check "empty-total" "0" "$(printf '%s' "$out" | jq -r '.total')" "empty log reports zero records"

# Populate a mixed log (including a malformed line).
cat > "$LOG" <<'JSONL'
{"ts":"2026-01-01T00:00:00Z","tool":"task-exec","status":"success","sandbox":"bwrap","apply_mode":"auto"}
{"ts":"2026-01-01T00:01:00Z","tool":"task-exec","status":"failed","sandbox":"bwrap","apply_mode":"auto","rolled_back":"true"}
{"ts":"2026-01-01T00:02:00Z","tool":"code-write","status":"written"}
this is not json
JSONL

out=$(HOME="$WORKDIR/home" SHUNT_AUDIT_LOG="$LOG" bash "$PLUGIN_DIR/scripts/shunt-local" stats --json)
check "total" "3" "$(printf '%s' "$out" | jq -r '.total')" "malformed line is ignored"
check "by-tool" "2" "$(printf '%s' "$out" | jq -r '.by_tool["task-exec"]')" "counts task-exec records"
check "by-tool-cw" "1" "$(printf '%s' "$out" | jq -r '.by_tool["code-write"]')" "counts code-write records"
check "by-status" "1" "$(printf '%s' "$out" | jq -r '.by_status["failed"]')" "counts failed records"
check "by-sandbox" "2" "$(printf '%s' "$out" | jq -r '.by_sandbox["bwrap"]')" "counts sandbox backend"
check "rolled-back" "1" "$(printf '%s' "$out" | jq -r '.rolled_back')" "counts rollbacks"

# Text mode is human-readable.
text=$(HOME="$WORKDIR/home" SHUNT_AUDIT_LOG="$LOG" bash "$PLUGIN_DIR/scripts/shunt-local" stats)
check "text-total" "yes" "$(printf '%s' "$text" | grep -q 'total records: 3' && echo yes || echo no)" "text output shows the total"

echo ""
echo "## $PASSED $FAILED"
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
