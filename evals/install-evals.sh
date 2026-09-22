#!/bin/bash
# Installer integration evals: run install.sh/uninstall.sh in an isolated HOME
# and validate the generated hook configs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKDIR="$(mktemp -d)"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
trap 'rm -rf "$WORKDIR"' EXIT

HOME_DIR="$WORKDIR/home"
mkdir -p "$HOME_DIR/.gemini" "$HOME_DIR/.cursor" "$WORKDIR/bin"

# Fake harness CLIs so install.sh takes every branch without doing anything.
for c in agy claude opencode cursor; do
  printf '#!/bin/sh\nexit 0\n' > "$WORKDIR/bin/$c"
  chmod +x "$WORKDIR/bin/$c"
done

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

echo "Installer Evals"
echo "────────────────────────────────────────────────────────────────"

set +e
HOME="$HOME_DIR" PATH="$WORKDIR/bin:$PATH" bash "$PLUGIN_DIR/install.sh" > "$WORKDIR/install.log" 2>&1
rc=$?
set -e
check "install-exit" "0" "$rc" "install.sh completes"

GEMINI="$HOME_DIR/.gemini/config/hooks.json"
CURSOR="$HOME_DIR/.cursor/hooks.json"
CONFIG="$HOME_DIR/.config/shunt-local/config.json"

check "config-created" "yes" "$([ -f "$CONFIG" ] && echo yes || echo no)" "config.json created"
check "gemini-valid" "yes" "$(jq -e . "$GEMINI" >/dev/null 2>&1 && echo yes || echo no)" "Antigravity hooks.json is valid JSON"
matchers=$(jq -r '[."shunt-local".PreToolUse[].matcher] | join(",")' "$GEMINI")
missing=""
for m in view_file run_command write_to_file grep_search; do
  case "$matchers" in *"$m"*) ;; *) missing="$missing $m" ;; esac
done
check "gemini-matchers" "" "$missing" "all Antigravity matchers registered"
check "gemini-absolute" "yes" \
  "$(jq -r '."shunt-local".PreToolUse[0].hooks[0].command' "$GEMINI" | grep -q "$PLUGIN_DIR/hooks/shunt_guard.py" && echo yes || echo no)" \
  "hook command points at the guard"

check "cursor-valid" "yes" "$(jq -e . "$CURSOR" >/dev/null 2>&1 && echo yes || echo no)" "Cursor hooks.json is valid JSON"
check "cursor-version" "1" "$(jq -r '.version' "$CURSOR")" "Cursor hooks version is 1"
check "cursor-pretooluse" "Grep,Read,Shell,Write" "$(jq -r '[.hooks.preToolUse[].matcher] | sort | join(",")' "$CURSOR")" "Cursor preToolUse matchers"
check "cursor-beforeread" "Read" "$(jq -r '[.hooks.beforeReadFile[].matcher] | join(",")' "$CURSOR")" "Cursor beforeReadFile registered"

check "opencode-plugin" "yes" \
  "$([ -f "$HOME_DIR/.config/opencode/plugins/shunt-local.ts" ] && echo yes || echo no)" "OpenCode plugin installed"
check "skill-installed" "yes" \
  "$([ -f "$HOME_DIR/.agents/skills/bulk-reader/SKILL.md" ] && echo yes || echo no)" "skills copied"

# Idempotency: a second install must not duplicate Cursor entries.
HOME="$HOME_DIR" PATH="$WORKDIR/bin:$PATH" bash "$PLUGIN_DIR/install.sh" >/dev/null 2>&1
check "idempotent-cursor" "4" "$(jq -r '[.hooks.preToolUse[]] | length' "$CURSOR")" "re-install does not duplicate hooks"

# shunt-update shares register.sh; --no-pull must re-register the same configs.
HOME="$HOME_DIR" PATH="$WORKDIR/bin:$PATH" bash "$PLUGIN_DIR/scripts/shunt-update" --no-pull > "$WORKDIR/update.log" 2>&1
check "update-exit" "0" "$?" "shunt-update --no-pull completes"
check "update-gemini" "yes" "$(jq -e '."shunt-local"' "$GEMINI" >/dev/null 2>&1 && echo yes || echo no)" "shunt-update re-registers Antigravity hooks"
check "update-cursor" "4" "$(jq -r '[.hooks.preToolUse[]] | length' "$CURSOR")" "shunt-update re-registers Cursor hooks"

# Uninstall removes what it added.
set +e
HOME="$HOME_DIR" PATH="$WORKDIR/bin:$PATH" bash "$PLUGIN_DIR/uninstall.sh" > "$WORKDIR/uninstall.log" 2>&1
set -e
check "uninstall-gemini" "null" "$(jq -r '."shunt-local" // "null"' "$GEMINI" 2>/dev/null)" "Antigravity hooks removed"
check "uninstall-cursor" "0" "$(jq -r '[.hooks.preToolUse[]?] | length' "$CURSOR" 2>/dev/null)" "Cursor shunt hooks removed"
check "uninstall-opencode" "no" \
  "$([ -f "$HOME_DIR/.config/opencode/plugins/shunt-local.ts" ] && echo yes || echo no)" "OpenCode plugin removed"

echo ""
echo "## $PASSED $FAILED"
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
