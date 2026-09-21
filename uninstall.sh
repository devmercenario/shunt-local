#!/bin/bash
# Uninstaller script for shunt-local

set -euo pipefail

SKILLS_DIR="${HOME}/.agents/skills"
GEMINI_CONFIG_DIR="${HOME}/.gemini/config"
HOOKS_FILE="${GEMINI_CONFIG_DIR}/hooks.json"

BIN_DIR="${HOME}/.local/bin"

echo "Uninstalling shunt-local..."

# 1. Remove binaries
rm -f "$BIN_DIR/bulk-read" "$BIN_DIR/code-write" "$BIN_DIR/shunt-update" "$BIN_DIR/shunt-local" "$BIN_DIR/task-exec"
echo "Removed binaries from $BIN_DIR"

# 2. Remove skills
rm -rf "$SKILLS_DIR/bulk-reader" "$SKILLS_DIR/code-writer" "$SKILLS_DIR/subtask-worker"
echo "Removed skills from $SKILLS_DIR"

# Clean state files
rm -f "${HOME}/.config/shunt-local/disabled"

# 2. Unregister from agy plugin if present
if command -v agy >/dev/null 2>&1; then
  agy plugin uninstall shunt-local 2>/dev/null || true
  echo "Unregistered plugin from agy"
fi

# 3. Remove hooks from ~/.gemini/config/hooks.json
if [ -f "$HOOKS_FILE" ] && command -v jq >/dev/null 2>&1; then
  tmp_hooks=$(mktemp)
  jq 'del(."shunt-local")' "$HOOKS_FILE" > "$tmp_hooks" && mv "$tmp_hooks" "$HOOKS_FILE"
  echo "Removed hooks from $HOOKS_FILE"
fi

echo "shunt-local uninstalled successfully."
