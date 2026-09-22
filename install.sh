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
INSTALL_ROOT_FILE="${CONFIG_DIR}/install_root"

echo "Installing shunt-local..."

# 1. Preflight dependencies check
for cmd in jq curl python3; do
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

# 5. Register repository as trusted in Antigravity ~/.gemini/trustedFolders.json.
#    A trusted directory is executed by the agent on every tool call, so never
#    trust one that is owned by somebody else or is writable by group/other
#    (a third party could then drop a backdoored hook into it).
if [ -d "${HOME}/.gemini" ] && command -v jq >/dev/null 2>&1; then
  repo_owner=$(stat -c '%u' "$SCRIPT_DIR" 2>/dev/null || stat -f '%u' "$SCRIPT_DIR" 2>/dev/null || echo "")
  if [ -n "$repo_owner" ] && [ "$repo_owner" != "$(id -u)" ]; then
    echo "⚠️  Not registering $SCRIPT_DIR as trusted: it is owned by uid $repo_owner (not you)." >&2
  elif [ -n "$(find "$SCRIPT_DIR" -maxdepth 0 \( -perm -0020 -o -perm -0002 \) 2>/dev/null)" ]; then
    echo "⚠️  Not registering $SCRIPT_DIR as trusted: it is writable by group/other." >&2
    echo "   Fix with: chmod go-w \"$SCRIPT_DIR\"" >&2
  else
    if [ ! -f "$TRUSTED_FOLDERS_FILE" ]; then
      echo "{}" > "$TRUSTED_FOLDERS_FILE"
    fi
    tmp_tf=$(umask 077 && mktemp) || exit 1
    jq --arg dir "$SCRIPT_DIR" '. + {($dir): "TRUST_FOLDER"}' "$TRUSTED_FOLDERS_FILE" > "$tmp_tf" && mv "$tmp_tf" "$TRUSTED_FOLDERS_FILE"
    printf '%s' "$SCRIPT_DIR" > "$INSTALL_ROOT_FILE"
    chmod 600 "$INSTALL_ROOT_FILE" 2>/dev/null || true
    echo "Ensured $SCRIPT_DIR is trusted in $TRUSTED_FOLDERS_FILE"
  fi
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

  tmp_hooks=$(umask 077 && mktemp) || exit 1
  jq \
    --arg size_hook "python3 \"$SCRIPT_DIR/hooks/shunt_guard.py\" --kind read" \
    --arg bash_hook "python3 \"$SCRIPT_DIR/hooks/shunt_guard.py\" --kind bash" \
    --arg write_hook "python3 \"$SCRIPT_DIR/hooks/shunt_guard.py\" --kind write" \
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
          },
          {
            "matcher": "write_to_file|replace_file_content|multi_replace_file_content",
            "hooks": [
              {
                "type": "command",
                "command": $write_hook
              }
            ]
          }
        ]
      }
    }' "$HOOKS_FILE" > "$tmp_hooks" && mv "$tmp_hooks" "$HOOKS_FILE"
  echo "Registered PreToolUse hooks in $HOOKS_FILE"
fi

# 8. Register with Claude Code CLI if present
if command -v claude >/dev/null 2>&1; then
  echo "Registering with Claude Code (claude)..."
  claude plugin install "$SCRIPT_DIR" 2>/dev/null || claude plugin add "$SCRIPT_DIR" 2>/dev/null || true
fi

# 9. Register OpenCode plugin if OpenCode is present
OPENCODE_CONFIG_DIR="${HOME}/.config/opencode"
OPENCODE_PLUGINS_DIR="${OPENCODE_CONFIG_DIR}/plugins"
if [ -d "$OPENCODE_CONFIG_DIR" ] || command -v opencode >/dev/null 2>&1; then
  mkdir -p "$OPENCODE_PLUGINS_DIR"
  chmod 700 "$OPENCODE_PLUGINS_DIR" 2>/dev/null || true
  cp "$SCRIPT_DIR/plugins/opencode/shunt-local.ts" "$OPENCODE_PLUGINS_DIR/shunt-local.ts"
  chmod 600 "$OPENCODE_PLUGINS_DIR/shunt-local.ts" 2>/dev/null || true
  echo "Installed OpenCode native plugin -> $OPENCODE_PLUGINS_DIR/shunt-local.ts"
fi

# 10. Register Cursor native hooks when Cursor is present.
#     Cursor expects {permission:"allow"|"deny"} and has its own matcher names,
#     so the shared guard is invoked with --harness cursor.
CURSOR_CONFIG_DIR="${HOME}/.cursor"
CURSOR_HOOKS_FILE="${CURSOR_CONFIG_DIR}/hooks.json"
if [ -d "$CURSOR_CONFIG_DIR" ] || command -v cursor >/dev/null 2>&1; then
  mkdir -p "$CURSOR_CONFIG_DIR"
  command -v jq >/dev/null 2>&1 || { echo "⚠️  jq is required to register Cursor hooks; skipping." >&2; }
  if command -v jq >/dev/null 2>&1; then
    [ -f "$CURSOR_HOOKS_FILE" ] || echo '{"version": 1, "hooks": {}}' > "$CURSOR_HOOKS_FILE"
    tmp_cur=$(umask 077 && mktemp) || exit 1
    jq \
      --arg read_hook "python3 \"$SCRIPT_DIR/hooks/shunt_guard.py\" --harness cursor --kind read" \
      --arg shell_hook "python3 \"$SCRIPT_DIR/hooks/shunt_guard.py\" --harness cursor --kind bash" \
      --arg write_hook "python3 \"$SCRIPT_DIR/hooks/shunt_guard.py\" --harness cursor --kind write" \
      '.version = 1
       | .hooks = (.hooks // {})
       | .hooks.preToolUse = ((.hooks.preToolUse // []) | map(select(.command | test("shunt_guard.py") | not)))
       | .hooks.preToolUse += [
           {"matcher": "Read", "command": $read_hook},
           {"matcher": "Shell", "command": $shell_hook},
           {"matcher": "Write", "command": $write_hook}
         ]
       | .hooks.beforeReadFile = ((.hooks.beforeReadFile // []) | map(select((.command // "") | test("shunt_guard.py") | not)))
       | .hooks.beforeReadFile += [ {"matcher": "Read", "command": $read_hook} ]' \
      "$CURSOR_HOOKS_FILE" > "$tmp_cur" && mv "$tmp_cur" "$CURSOR_HOOKS_FILE"
    chmod 600 "$CURSOR_HOOKS_FILE" 2>/dev/null || true
    echo "Registered Cursor hooks in $CURSOR_HOOKS_FILE"
  fi
fi

# 11. Verify PATH includes ~/.local/bin (important for macOS and non-standard Linux setups)
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo ""
    echo "⚠️  NOTE: $BIN_DIR is not currently in your \$PATH."
    echo "   To use shunt-local, task-exec, and bulk-read from anywhere, add this to your shell config (~/.zshrc or ~/.bashrc):"
    echo "   export PATH=\"\$HOME/.local/bin:\$PATH\""
    ;;
esac

echo ""
echo "Installation complete!"
echo "Configuration: $CONFIG_DIR/config.json"
echo "To verify tests, run: bash $SCRIPT_DIR/evals/run.sh"
