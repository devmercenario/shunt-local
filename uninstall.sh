#!/bin/bash
# Uninstaller for shunt-local.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/register.sh
. "$SCRIPT_DIR/scripts/lib/register.sh"

CONFIG_DIR="${HOME}/.config/shunt-local"
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

# 1. Binaries and skills
shunt_unlink_binaries
echo "Removed binaries from ${HOME}/.local/bin"
shunt_remove_skills
echo "Removed skills from ${HOME}/.agents/skills"

# 2. Clean state files
rm -f "${CONFIG_DIR}/disabled"

# 3. Unregister from the harness CLIs if present
if command -v agy >/dev/null 2>&1; then
  agy plugin uninstall shunt-local 2>/dev/null || true
  echo "Unregistered plugin from agy"
fi
if command -v claude >/dev/null 2>&1; then
  claude plugin uninstall shunt-local 2>/dev/null || claude plugin remove shunt-local 2>/dev/null || true
  echo "Unregistered plugin from claude"
fi

# 4. Remove hooks, trust entry and OpenCode plugin
shunt_unregister_antigravity_hooks
shunt_untrust_repo
shunt_remove_opencode_plugin
shunt_unregister_cursor_hooks

# 5. Purge configuration (removes API keys and all user config)
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
