#!/bin/bash
# Doctor evals: the diagnostic subcommand reports and exits correctly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKDIR="$(mktemp -d)"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/home/.config/shunt-local"

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

echo "Doctor Evals"
echo "────────────────────────────────────────────────────────────────"

# Healthy config (localhost, server offline is only a warning).
cat > "$WORKDIR/home/.config/shunt-local/config.json" <<'JSON'
{"enabled": true, "endpoint": "http://127.0.0.1:8080/v1/chat/completions", "min_lines": 350}
JSON
chmod 600 "$WORKDIR/home/.config/shunt-local/config.json"

set +e
out=$(HOME="$WORKDIR/home" bash "$PLUGIN_DIR/scripts/shunt-local" doctor 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then printf '%s\n' "$out" >&2; fi
check "healthy-exit" "0" "$rc" "doctor exits 0 with warnings only"
check "healthy-endpoint" "yes" "$(printf '%s' "$out" | grep -q 'pass.*endpoint' && echo yes || echo no)" "endpoint validated"

# JSON mode is machine-readable.
json=$(HOME="$WORKDIR/home" bash "$PLUGIN_DIR/scripts/shunt-local" doctor --json 2>/dev/null || true)
check "json-status" "warn" "$(printf '%s' "$json" | jq -r '.status')" "JSON status reflects warnings"
check "json-checks" "true" "$(printf '%s' "$json" | jq -r '.checks | length > 0')" "JSON includes checks"

# Broken endpoint must fail.
cat > "$WORKDIR/home/.config/shunt-local/config.json" <<'JSON'
{"enabled": true, "endpoint": "ftp://evil.example/v1"}
JSON
set +e
HOME="$WORKDIR/home" bash "$PLUGIN_DIR/scripts/shunt-local" doctor >/dev/null 2>&1
rc=$?
set -e
check "bad-endpoint-exit" "1" "$rc" "doctor fails on an invalid endpoint"

# Loose permissions are reported.
cat > "$WORKDIR/home/.config/shunt-local/config.json" <<'JSON'
{"enabled": true, "endpoint": "http://127.0.0.1:8080/v1/chat/completions"}
JSON
chmod 644 "$WORKDIR/home/.config/shunt-local/config.json"
out=$(HOME="$WORKDIR/home" bash "$PLUGIN_DIR/scripts/shunt-local" doctor 2>&1 || true)
check "config-perms" "yes" "$(printf '%s' "$out" | grep -q 'config-perms' && echo yes || echo no)" "loose config permissions reported"
check "json-warn-status" "warn" "$(HOME="$WORKDIR/home" bash "$PLUGIN_DIR/scripts/shunt-local" doctor --json 2>/dev/null | jq -r '.status' || true)" "loose perms yield warn status"

echo ""
echo "## $PASSED $FAILED"
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
