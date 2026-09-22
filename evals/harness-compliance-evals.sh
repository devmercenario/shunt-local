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

# ---- Cross-platform Python guard (used by hooks/hooks.json and Windows) ----
GUARD="$PLUGIN_DIR/hooks/shunt_guard.py"
guard_run() { printf '%s' "$1" | HOME="$WORKDIR/home" __SHUNT_TEST_MOCK_ONLINE=1 python3 "$GUARD" "${@:2}" 2>/dev/null; }

g=$(guard_run "{\"toolCall\":{\"name\":\"view_file\",\"args\":{\"AbsolutePath\":\"$WORKDIR/large.txt\"}}}" --harness antigravity)
check "guard-antigravity" "deny" "$(printf '%s' "$g" | jq -r '.decision // empty')" "python guard emits Antigravity deny"

g=$(guard_run "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$WORKDIR/large.txt\"}}")
check "guard-claude" "deny" "$(printf '%s' "$g" | jq -r '.hookSpecificOutput.permissionDecision // empty')" "python guard emits Claude nested deny"

g=$(guard_run "{\"tool_name\":\"Shell\",\"tool_input\":{\"command\":\"cat $WORKDIR/large.txt\"}}" --harness cursor --kind bash)
check "guard-cursor" "deny" "$(printf '%s' "$g" | jq -r '.permission // empty')" "python guard emits Cursor deny"

g=$(guard_run "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$WORKDIR/small.txt\"}}")
check "guard-allow-silent" "" "$g" "python guard allow emits nothing"

guard_write() { ( cd "$WORKDIR/work" && printf '%s' "$1" | HOME="$WORKDIR/home" python3 "$GUARD" --kind write "${@:2}" 2>/dev/null ); }
mkdir -p "$WORKDIR/work/.github/workflows"
g=$(guard_write "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WORKDIR/work/.github/workflows/ci.yml\"}}")
check "guard-write-sensitive" "deny" "$(printf '%s' "$g" | jq -r '.hookSpecificOutput.permissionDecision // empty')" "write to CI file is denied"
g=$(guard_write "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$WORKDIR/work/src/ok.py\"}}")
check "guard-write-normal" "" "$g" "normal write is allowed"
g=$(guard_write "{\"turn_id\":\"t\",\"tool_name\":\"apply_patch\",\"tool_input\":{\"command\":\"*** Begin Patch\\n*** Update File: .git/config\\n+ x\\n*** End Patch\"}}")
check "guard-codex-patch" "deny" "$(printf '%s' "$g" | jq -r '.hookSpecificOutput.permissionDecision // empty')" "apply_patch to .git is denied"
g=$(guard_write "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WORKDIR/work/package.json\"}}" --harness cursor)
check "guard-cursor-write" "deny" "$(printf '%s' "$g" | jq -r '.permission // empty')" "Cursor write to package.json is denied"
g=$(guard_write "{\"toolCall\":{\"name\":\"write_to_file\",\"args\":{\"TargetFile\":\"$WORKDIR/work/.env\"}}}" --harness antigravity)
check "guard-antigravity-write" "deny" "$(printf '%s' "$g" | jq -r '.decision // empty')" "Antigravity write to .env is denied"

check "claude-write-matcher" "yes" \
  "$(jq -r '.hooks.PreToolUse[] | select(.matcher | test("Write")) | .matcher' "$PLUGIN_DIR/hooks/hooks.json" | grep -q . && echo yes || echo no)" \
  "Claude hook matches Write|Edit"
check "claude-python-fallback" "yes" \
  "$(jq -r '.hooks.PreToolUse[].hooks[].command' "$PLUGIN_DIR/hooks/hooks.json" | grep -q '|| python ' && echo yes || echo no)" \
  "Claude hook falls back to python when python3 is missing"
check "antigravity-write-matcher" "yes" \
  "$(grep -q 'write_to_file' "$PLUGIN_DIR/scripts/lib/register.sh" && echo yes || echo no)" \
  "installer registers Antigravity write matcher"

# ---- Sensitive reads + Cursor beforeReadFile ----
printf 'SECRET=1\n' > "$WORKDIR/work/.env"
mkdir -p "$WORKDIR/home/.ssh"; printf 'KEY\n' > "$WORKDIR/home/.ssh/id_rsa"
g=$(guard_run "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$WORKDIR/work/.env\"}}")
check "guard-sensitive-read" "deny" "$(printf '%s' "$g" | jq -r '.hookSpecificOutput.permissionDecision // empty')" "reading .env is denied"
g=$(guard_run "{\"tool_name\":\"mcp__filesystem__read_file\",\"tool_input\":{\"path\":\"$WORKDIR/home/.ssh/id_rsa\"}}")
check "guard-mcp-read" "deny" "$(printf '%s' "$g" | jq -r '.hookSpecificOutput.permissionDecision // empty')" "MCP read of a private key is denied"
br=$(python3 -c "import json; print(json.dumps({'file_path':'$WORKDIR/large.txt','content':'x','attachments':[{'type':'file','file_path':'$WORKDIR/work/.env'}]}))")
g=$(guard_run "$br" --harness cursor --kind read)
check "guard-before-readfile" "deny" "$(printf '%s' "$g" | jq -r '.permission // empty')" "Cursor beforeReadFile blocks sensitive attachments"
check "cursor-before-readfile-registered" "yes" \
  "$(grep -q 'beforeReadFile' "$PLUGIN_DIR/scripts/lib/register.sh" && echo yes || echo no)" \
  "installer registers Cursor beforeReadFile"

# ---- Grep guidance ----
g=$(guard_run "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Grep\",\"tool_input\":{\"pattern\":\"TODO\",\"output_mode\":\"content\"}}" --kind grep)
check "guard-grep-context" "true" "$(printf '%s' "$g" | jq -r '(.hookSpecificOutput.additionalContext // "" | length) > 0')" "Grep content adds additionalContext"
g=$(guard_run "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Grep\",\"tool_input\":{\"pattern\":\"TODO\"}}" --kind grep)
check "guard-grep-allow" "" "$g" "Grep without content is allowed silently"
check "claude-grep-matcher" "yes" \
  "$(jq -r '.hooks.PreToolUse[] | select(.matcher | test("Grep")) | .matcher' "$PLUGIN_DIR/hooks/hooks.json" | grep -q . && echo yes || echo no)" \
  "Claude hook matches Grep"
check "claude-deny-rules" "true" \
  "$(jq -r '.permissions.deny | length > 0' "$PLUGIN_DIR/settings.json" 2>/dev/null)" \
  "plugin settings.json denies reading secrets (@-refs bypass hooks)"

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
import re
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
if not text.startswith("---"):
    print("nofrontmatter"); raise SystemExit
fm = text.split("---", 2)[1]
try:
    import yaml
    data = yaml.safe_load(fm) or {}
    print("alwaysapply" if data.get("alwaysApply") is True else "missing")
except Exception:
    # No PyYAML available: fall back to a conservative textual check.
    ok = re.search(r"^alwaysApply:\s*true\s*$", fm, re.M) and not re.search(r"^globs:\s*\*\s*$", fm, re.M)
    print("alwaysapply" if ok else "missing")
PY
)
check "cursor-rule-frontmatter" "alwaysapply" "$mdc_check" "Cursor rule frontmatter is valid YAML and alwaysApply: true"

# Installer must register Cursor hooks with the cursor output format.
check "install-cursor-hooks" "yes" \
  "$(grep -q 'register.sh' "$PLUGIN_DIR/install.sh" && grep -q -- '--harness cursor' "$PLUGIN_DIR/scripts/lib/register.sh" && echo yes || echo no)" \
  "install.sh registers Cursor hooks with cursor format"
check "update-cursor-hooks" "yes" \
  "$(grep -q 'register.sh' "$PLUGIN_DIR/scripts/shunt-update" && grep -q -- '--harness cursor' "$PLUGIN_DIR/scripts/lib/register.sh" && echo yes || echo no)" \
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
