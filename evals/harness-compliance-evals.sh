#!/bin/bash
# Harness compliance evals.
#
# Verifies that the hooks/manifests follow each supported harness's contract:
#   - Antigravity: top-level {"decision":"allow"|"deny"}
#   - Claude Code / Codex: hookSpecificOutput.permissionDecision (no auto-approve)
#   - Cursor: {"permission":"allow"|"deny"} native preToolUse hooks
#   - manifests / rule frontmatter are valid

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

echo "Harness Compliance Evals"
echo "────────────────────────────────────────────────────────────────"

mkdir -p "$WORKDIR/home"
seq 1 1000 > "$WORKDIR/large.txt"
seq 1 10 > "$WORKDIR/small.txt"

READ_HOOK="$PLUGIN_DIR/hooks/check-file-size"
BASH_HOOK="$PLUGIN_DIR/hooks/check-bash-read"

run_hook() { # hook, payload, [env harness]
  local hook="$1" payload="$2" harness="${3:-}"
  if [ -n "$harness" ]; then
    printf '%s' "$payload" | HOME="$WORKDIR/home" __SHUNT_TEST_MOCK_ONLINE=1 SHUNT_HOOK_HARNESS="$harness" bash "$hook" 2>/dev/null
  else
    printf '%s' "$payload" | HOME="$WORKDIR/home" __SHUNT_TEST_MOCK_ONLINE=1 bash "$hook" 2>/dev/null
  fi
}

# ---- Antigravity ----
agy_deny=$(run_hook "$READ_HOOK" "{\"toolCall\":{\"name\":\"view_file\",\"args\":{\"AbsolutePath\":\"$WORKDIR/large.txt\"}}}")
check "antigravity-deny" "deny" "$(printf '%s' "$agy_deny" | jq -r '.decision // empty')" "view_file over threshold -> top-level deny"
check "antigravity-reason" "yes" "$([ -n "$(printf '%s' "$agy_deny" | jq -r '.reason // empty')" ] && echo yes || echo no)" "deny carries a reason"
agy_allow=$(run_hook "$READ_HOOK" "{\"toolCall\":{\"name\":\"view_file\",\"args\":{\"AbsolutePath\":\"$WORKDIR/small.txt\"}}}")
check "antigravity-allow" "allow" "$(printf '%s' "$agy_allow" | jq -r '.decision // empty')" "small read -> top-level allow"

# ---- Claude Code ----
claude_deny=$(run_hook "$READ_HOOK" "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$WORKDIR/large.txt\"}}")
check "claude-deny-format" "deny" "$(printf '%s' "$claude_deny" | jq -r '.hookSpecificOutput.permissionDecision // empty')" "uses hookSpecificOutput.permissionDecision"
check "claude-deny-event" "PreToolUse" "$(printf '%s' "$claude_deny" | jq -r '.hookSpecificOutput.hookEventName // empty')" "names the PreToolUse event"
check "claude-deny-reason" "yes" "$([ -n "$(printf '%s' "$claude_deny" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')" ] && echo yes || echo no)" "deny carries permissionDecisionReason"
check "claude-no-deprecated" "null" "$(printf '%s' "$claude_deny" | jq -r '.decision // "null"')" "does not emit deprecated top-level decision"
claude_allow=$(run_hook "$READ_HOOK" "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$WORKDIR/small.txt\"}}")
check "claude-allow-silent" "" "$claude_allow" "allow emits nothing (no silent auto-approve)"
claude_bash=$(run_hook "$BASH_HOOK" "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat $WORKDIR/large.txt\"}}")
check "claude-bash-deny" "deny" "$(printf '%s' "$claude_bash" | jq -r '.hookSpecificOutput.permissionDecision // empty')" "bash bulk read -> nested deny"

# ---- Codex (Claude-compatible tool names, no hook_event_name) ----
codex_deny=$(run_hook "$BASH_HOOK" "{\"turn_id\":\"t1\",\"tool_name\":\"Bash\",\"tool_use_id\":\"u1\",\"tool_input\":{\"command\":\"cat $WORKDIR/large.txt\"}}")
check "codex-deny-format" "deny" "$(printf '%s' "$codex_deny" | jq -r '.hookSpecificOutput.permissionDecision // empty')" "Codex gets nested permissionDecision"
codex_allow=$(run_hook "$BASH_HOOK" "{\"turn_id\":\"t1\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat $WORKDIR/small.txt\"}}")
check "codex-allow-silent" "" "$codex_allow" "Codex allow emits nothing"

# ---- Cursor (native format) ----
cursor_deny=$(run_hook "$BASH_HOOK" "{\"tool_name\":\"Shell\",\"tool_input\":{\"command\":\"cat $WORKDIR/large.txt\"}}" cursor)
check "cursor-deny-format" "deny" "$(printf '%s' "$cursor_deny" | jq -r '.permission // empty')" "Cursor gets {\"permission\":\"deny\"}"
check "cursor-agent-msg" "yes" "$([ -n "$(printf '%s' "$cursor_deny" | jq -r '.agent_message // empty')" ] && echo yes || echo no)" "Cursor deny carries agent_message"
cursor_allow=$(run_hook "$BASH_HOOK" "{\"tool_name\":\"Shell\",\"tool_input\":{\"command\":\"cat $WORKDIR/small.txt\"}}" cursor)
check "cursor-allow-format" "allow" "$(printf '%s' "$cursor_allow" | jq -r '.permission // empty')" "Cursor allow is {\"permission\":\"allow\"}"

# ---- Manifests / configuration ----
check "claude-matcher-powershell" "Bash|PowerShell" \
  "$(jq -r '.hooks.PreToolUse[] | select(.matcher | test("PowerShell")) | .matcher' "$PLUGIN_DIR/hooks/hooks.json")" \
  "Claude hook matches Bash|PowerShell"

check "plugin-json-no-claude-hooks" "null" \
  "$(jq -r '.hooks // "null"' "$PLUGIN_DIR/plugin.json")" \
  "Antigravity manifest does not advertise Claude matchers"

if [ -f "$PLUGIN_DIR/.codex-plugin/plugin.json" ]; then codex_manifest=yes; else codex_manifest=no; fi
check "codex-manifest" "yes" "$codex_manifest" ".codex-plugin/plugin.json exists"
check "codex-hooks-path" "./hooks/hooks.json" \
  "$(jq -r '.hooks // empty' "$PLUGIN_DIR/.codex-plugin/plugin.json" 2>/dev/null)" "Codex manifest points at hooks/hooks.json"

check "claude-plugin-manifest" "shunt-local" \
  "$(jq -r '.name // empty' "$PLUGIN_DIR/.claude-plugin/plugin.json")" ".claude-plugin/plugin.json has a name"

# Cursor rule frontmatter must be valid YAML with alwaysApply (globs: * was invalid).
mdc_check=$(python3 - "$PLUGIN_DIR/.cursor/rules/shunt-local.mdc" <<'PY'
import sys
try:
    import yaml
except Exception:
    print("noyaml"); raise SystemExit
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
if not text.startswith("---"):
    print("nofrontmatter"); raise SystemExit
fm = text.split("---", 2)[1]
try:
    data = yaml.safe_load(fm) or {}
except Exception as exc:
    print(f"yamlerror:{exc}"); raise SystemExit
print("alwaysapply" if data.get("alwaysApply") is True else "missing")
PY
)
check "cursor-rule-frontmatter" "alwaysapply" "$mdc_check" "Cursor rule frontmatter is valid YAML and alwaysApply: true"

# Installer must register Cursor hooks with the cursor output format.
check "install-cursor-hooks" "yes" \
  "$(grep -q 'SHUNT_HOOK_HARNESS=cursor' "$PLUGIN_DIR/install.sh" && echo yes || echo no)" \
  "install.sh registers Cursor hooks with cursor format"
check "update-cursor-hooks" "yes" \
  "$(grep -q 'SHUNT_HOOK_HARNESS=cursor' "$PLUGIN_DIR/scripts/shunt-update" && echo yes || echo no)" \
  "shunt-update refreshes Cursor hooks"

# Skills must have name + description frontmatter (Agent Skills requirement).
skills_ok=yes
for f in "$PLUGIN_DIR"/skills/*/SKILL.md; do
  grep -q '^name:' "$f" || skills_ok=no
  grep -q '^description:' "$f" || skills_ok=no
done
check "skills-frontmatter" "yes" "$skills_ok" "all SKILL.md files declare name + description"

echo ""
echo "## $PASSED $FAILED"
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
