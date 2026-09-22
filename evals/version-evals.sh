#!/bin/bash
# Version-discipline evals for scripts/bump-version.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUMP="$PLUGIN_DIR/scripts/bump-version"

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

echo "Version Evals"
echo "────────────────────────────────────────────────────────────────"

# Repository manifests are consistent.
check "repo-consistent" "0" "$("$BUMP" --check >/dev/null 2>&1; echo $?)" "all repo manifests agree"

# Work on a copy so the test never mutates the repository.
ROOT="$WORKDIR/root"
mkdir -p "$ROOT/.claude-plugin" "$ROOT/.codex-plugin" "$ROOT/plugins/opencode"
for f in plugin.json .claude-plugin/plugin.json .codex-plugin/plugin.json .claude-plugin/marketplace.json plugins/opencode/package.json; do
  cp "$PLUGIN_DIR/$f" "$ROOT/$f"
done

check "copy-consistent" "0" "$("$BUMP" --root "$ROOT" --check >/dev/null 2>&1; echo $?)" "copied manifests agree"
check "check-wrong-version" "1" "$("$BUMP" --root "$ROOT" --check 9.9.9 >/dev/null 2>&1; echo $?)" "check rejects a wrong version"

"$BUMP" --root "$ROOT" 9.9.9 >/dev/null
check "set-version" "0" "$("$BUMP" --root "$ROOT" --check 9.9.9 >/dev/null 2>&1; echo $?)" "bump sets the version everywhere"
check "set-marketplace" "9.9.9" "$(jq -r '.plugins[0].version' "$ROOT/.claude-plugin/marketplace.json")" "marketplace plugin version updated"
check "set-nonexistent-file" "9.9.9" "$("$BUMP" --root "$ROOT" --check)" "check prints the shared version"

check "invalid-version" "2" "$("$BUMP" --root "$ROOT" bad >/dev/null 2>&1; echo $?)" "invalid version is rejected"

# Inconsistency detection.
jq '.version = "1.2.3"' "$ROOT/plugin.json" > "$ROOT/plugin.json.tmp" && mv "$ROOT/plugin.json.tmp" "$ROOT/plugin.json"
check "detect-mismatch" "1" "$("$BUMP" --root "$ROOT" --check >/dev/null 2>&1; echo $?)" "mismatch is detected"

echo ""
echo "## $PASSED $FAILED"
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
