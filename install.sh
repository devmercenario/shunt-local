#!/bin/bash
# Installer script for shunt-local (Google Antigravity & Claude Code)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILLS_DIR="${HOME}/.agents/skills"
BIN_DIR="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.config/shunt-local"
GEMINI_CONFIG_DIR="${HOME}/.gemini/config"
HOOKS_FILE="${GEMINI_CONFIG_DIR}/hooks.json"
TRUSTED_FOLDERS_FILE="${HOME}/.gemini/trustedFolders.json"

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
chmod 700 "$CONFIG_DIR" 2>/dev/null || true
if [ ! -f "$CONFIG_DIR/config.json" ]; then
  cp "$SCRIPT_DIR/config.example.json" "$CONFIG_DIR/config.json"
  echo "Created default config at $CONFIG_DIR/config.json"
else
  echo "Found existing config at $CONFIG_DIR/config.json"
fi
chmod 600 "$CONFIG_DIR/config.json" 2>/dev/null || true

# 3. Install binaries in ~/.local/bin
mkdir -p "$BIN_DIR"
for bin_script in bulk-read code-write shunt-update shunt-local task-exec; do
  target="$SCRIPT_DIR/scripts/$bin_script"
  if [ -f "$target" ]; then
    chmod +x "$target"
    ln -sf "$target" "$BIN_DIR/$bin_script"
    echo "Linked binary '$bin_script' -> $BIN_DIR/$bin_script"
  fi
done

# 4. Install skills for Antigravity & Claude Code (copying to keep realpath inside ~/.agents/)
mkdir -p "$SKILLS_DIR"
for skill in "$SCRIPT_DIR"/skills/*; do
  if [ -d "$skill" ]; then
    skill_name="$(basename "$skill")"
    rm -rf "$SKILLS_DIR/$skill_name"
    cp -r "$skill" "$SKILLS_DIR/$skill_name"
    echo "Installed skill '$skill_name' -> $SKILLS_DIR/$skill_name"
  fi
done

# 5. Ensure repository is trusted in Antigravity ~/.gemini/trustedFolders.json
if [ -d "${HOME}/.gemini" ] && command -v jq >/dev/null 2>&1; then
  if [ ! -f "$TRUSTED_FOLDERS_FILE" ]; then
    echo "{}" > "$TRUSTED_FOLDERS_FILE"
  fi
  tmp_tf=$(mktemp)
  jq --arg dir "$SCRIPT_DIR" '. + {($dir): "TRUST_FOLDER"}' "$TRUSTED_FOLDERS_FILE" > "$tmp_tf" && mv "$tmp_tf" "$TRUSTED_FOLDERS_FILE"
  echo "Ensured $SCRIPT_DIR is trusted in $TRUSTED_FOLDERS_FILE"
fi

# 6. Register with Antigravity CLI (agy) if present
if command -v agy >/dev/null 2>&1; then
  echo "Registering with Antigravity CLI (agy)..."
  agy plugin install "$SCRIPT_DIR" 2>/dev/null || true
fi

# 7. Register PreToolUse lifecycle hooks in Google Antigravity (~/.gemini/config/hooks.json)
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
