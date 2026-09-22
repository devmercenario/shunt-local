#!/bin/bash
# Packaging evals: distribution manifests are valid and consistent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

echo "Packaging Evals"
echo "────────────────────────────────────────────────────────────────"

check "claude-plugin" "shunt-local" "$(jq -r '.name // empty' "$PLUGIN_DIR/.claude-plugin/plugin.json")" "Claude plugin manifest has a name"
check "claude-marketplace" "true" "$(jq -r '.plugins | length > 0' "$PLUGIN_DIR/.claude-plugin/marketplace.json" 2>/dev/null)" "marketplace lists at least one plugin"
check "marketplace-source" "./" "$(jq -r '.plugins[0].source // empty' "$PLUGIN_DIR/.claude-plugin/marketplace.json")" "marketplace source points at the repo"
check "codex-hooks-exists" "yes" "$([ -f "$PLUGIN_DIR/hooks/hooks.json" ] && echo yes || echo no)" "Codex hooks file exists"
check "codex-manifest-hooks" "./hooks/hooks.json" "$(jq -r '.hooks // empty' "$PLUGIN_DIR/.codex-plugin/plugin.json")" "Codex manifest points at hooks"
check "opencode-package" "opencode-shunt-local" "$(jq -r '.name // empty' "$PLUGIN_DIR/plugins/opencode/package.json")" "OpenCode npm package named"
check "opencode-main-exists" "yes" "$([ -f "$PLUGIN_DIR/plugins/opencode/$(jq -r '.main' "$PLUGIN_DIR/plugins/opencode/package.json")" ] && echo yes || echo no)" "OpenCode main file exists"
check "settings-deny" "true" "$(jq -r '.permissions.deny | length > 0' "$PLUGIN_DIR/settings.json")" "settings.json ships deny rules"

# The three sensitive-name copies must not drift (canonical txt vs OpenCode TS).
txt_names=$(grep -v '^#' "$PLUGIN_DIR/scripts/lib/sensitive-names.txt" | tr -d '\r' | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u)
ts_names=$(python3 - "$PLUGIN_DIR/plugins/opencode/shunt-local.ts" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"new Set\(\[(.*?)\]\)", s, re.S)
names = sorted(set(re.findall(r"'([^']+)'", m.group(1))))
print("\n".join(names))
PY
)
if [ "$txt_names" = "$ts_names" ]; then same=yes; else same=no; fi
check "sensitive-list-sync" "yes" "$same" "OpenCode sensitive list matches the canonical file"
check "architecture-doc" "yes" \
  "$([ -f "$PLUGIN_DIR/docs/architecture.md" ] && [ -f "$PLUGIN_DIR/docs/threat-model.md" ] && echo yes || echo no)" \
  "architecture and threat-model docs exist"

versions=$(for f in "$PLUGIN_DIR/plugin.json" "$PLUGIN_DIR/.claude-plugin/plugin.json" "$PLUGIN_DIR/.codex-plugin/plugin.json" "$PLUGIN_DIR/plugins/opencode/package.json"; do jq -r '.version // empty' "$f"; done | sort -u | wc -l | tr -d ' ')
check "version-consistency" "1" "$versions" "all manifests share one version"

echo ""
echo "## $PASSED $FAILED"
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
