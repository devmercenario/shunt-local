#!/bin/bash
# Installer script for shunt-local (Google Antigravity & Claude Code)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILLS_DIR="${HOME}/.agents/skills"
CONFIG_DIR="${HOME}/.config/shunt-local"
GEMINI_CONFIG_DIR="${HOME}/.gemini/config"
HOOKS_FILE="${GEMINI_CONFIG_DIR}/hooks.json"

echo "Installing shunt-local..."

# 1. Preflight dependencies check
for cmd in jq curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: missing required dependency: $cmd" >&2
    echo "Please install $cmd using your package manager." >&2
    exit 1
  fi
done

# 2. Setup user configuration directory
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/config.json" ]; then
  cp "$SCRIPT_DIR/config.example.json" "$CONFIG_DIR/config.json"
  echo "Created default config at $CONFIG_DIR/config.json"
else
  echo "Found existing config at $CONFIG_DIR/config.json"
fi

# 3. Symlink skills for Antigravity & Claude Code
mkdir -p "$SKILLS_DIR"
for skill in "$SCRIPT_DIR"/skills/*; do
  if [ -d "$skill" ]; then
    skill_name="$(basename "$skill")"
    ln -sf "$skill" "$SKILLS_DIR/$skill_name"
    echo "Linked skill '$skill_name' -> $SKILLS_DIR/$skill_name"
  fi
done

# 4. Register with Antigravity CLI (agy) if present
if command -v agy >/dev/null 2>&1; then
  echo "Registering with Antigravity CLI (agy)..."
  agy plugin install "$SCRIPT_DIR" 2>/dev/null || true
fi

# 5. Register PreToolUse lifecycle hooks in Google Antigravity (~/.gemini/config/hooks.json)
if [ -d "$GEMINI_CONFIG_DIR" ] || command -v agy >/dev/null 2>&1; then
  mkdir -p "$GEMINI_CONFIG_DIR"
  if [ ! -f "$HOOKS_FILE" ]; then
    echo "{}" > "$HOOKS_FILE"
  fi

  tmp_hooks=$(mktemp)
  jq \
    --arg size_hook "$SCRIPT_DIR/hooks/check-file-size" \
    --arg bash_hook "$SCRIPT_DIR/hooks/check-bash-read" \
    '. + {
      "shunt-local": {
        "PreToolUse": [
          {
            "matcher": "view_file",
            "hooks": [
              {
                "type": "command",
                "command": $size_hook
              }
            ]
          },
          {
            "matcher": "run_command",
            "hooks": [
              {
                "type": "command",
                "command": $bash_hook
              }
            ]
          }
        ]
      }
    }' "$HOOKS_FILE" > "$tmp_hooks" && mv "$tmp_hooks" "$HOOKS_FILE"
  echo "Registered PreToolUse hooks in $HOOKS_FILE"
fi

echo ""
echo "Installation complete!"
echo "Configuration: $CONFIG_DIR/config.json"
echo "To verify tests, run: bash $SCRIPT_DIR/evals/run.sh"
