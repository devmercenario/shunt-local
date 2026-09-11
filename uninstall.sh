#!/bin/bash
# Uninstaller script for shunt-local

set -euo pipefail

SKILLS_DIR="${HOME}/.agents/skills"
GEMINI_CONFIG_DIR="${HOME}/.gemini/config"
HOOKS_FILE="${GEMINI_CONFIG_DIR}/hooks.json"

echo "Uninstalling shunt-local..."

# 1. Remove skills symlinks
rm -f "$SKILLS_DIR/bulk-reader" "$SKILLS_DIR/code-writer"
echo "Removed skill symlinks from $SKILLS_DIR"

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
