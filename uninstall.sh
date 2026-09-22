#!/bin/bash
# Uninstaller script for shunt-local

set -euo pipefail

SKILLS_DIR="${HOME}/.agents/skills"
GEMINI_CONFIG_DIR="${HOME}/.gemini/config"
HOOKS_FILE="${GEMINI_CONFIG_DIR}/hooks.json"
CONFIG_DIR="${HOME}/.config/shunt-local"

BIN_DIR="${HOME}/.local/bin"

PURGE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge) PURGE=true; shift ;;
    -h|--help)
      echo "Usage: uninstall.sh [--purge]"
      echo "  --purge  Also remove configuration directory (~/.config/shunt-local) including any stored API keys."
      exit 0
      ;;
    *) shift ;;
  esac
done

echo "Uninstalling shunt-local..."

# 1. Remove binaries
rm -f "$BIN_DIR/bulk-read" "$BIN_DIR/code-write" "$BIN_DIR/shunt-update" "$BIN_DIR/shunt-local" "$BIN_DIR/task-exec"
echo "Removed binaries from $BIN_DIR"

# 2. Remove skills
rm -rf "$SKILLS_DIR/bulk-reader" "$SKILLS_DIR/code-writer" "$SKILLS_DIR/subtask-worker"
echo "Removed skills from $SKILLS_DIR"

# 3. Clean state files
rm -f "${CONFIG_DIR}/disabled"

# 4. Unregister from agy plugin if present
if command -v agy >/dev/null 2>&1; then
  agy plugin uninstall shunt-local 2>/dev/null || true
  echo "Unregistered plugin from agy"
fi

# 5. Unregister from Claude Code if present
if command -v claude >/dev/null 2>&1; then
  claude plugin uninstall shunt-local 2>/dev/null || claude plugin remove shunt-local 2>/dev/null || true
  echo "Unregistered plugin from claude"
fi

# 6. Remove hooks from ~/.gemini/config/hooks.json
if [ -f "$HOOKS_FILE" ] && command -v jq >/dev/null 2>&1; then
  tmp_hooks=$(umask 077 && mktemp) || exit 1
  jq 'del(."shunt-local")' "$HOOKS_FILE" > "$tmp_hooks" && mv "$tmp_hooks" "$HOOKS_FILE"
  echo "Removed hooks from $HOOKS_FILE"
fi

# 7. Remove OpenCode plugin if present
OPENCODE_PLUGIN="${HOME}/.config/opencode/plugins/shunt-local.ts"
if [ -f "$OPENCODE_PLUGIN" ]; then
  rm -f "$OPENCODE_PLUGIN"
  echo "Removed OpenCode plugin from $OPENCODE_PLUGIN"
fi

# 7. Purge configuration (removes API keys and all user config)
if [ "$PURGE" = "true" ]; then
  if [ -d "$CONFIG_DIR" ]; then
    rm -rf "$CONFIG_DIR"
    echo "Purged configuration directory: $CONFIG_DIR"
  fi
else
  if [ -d "$CONFIG_DIR" ]; then
    echo "⚠️  Configuration directory retained: $CONFIG_DIR"
    echo "   To remove it (including any stored API keys), re-run with: ./uninstall.sh --purge"
  fi
fi

echo "shunt-local uninstalled successfully."
