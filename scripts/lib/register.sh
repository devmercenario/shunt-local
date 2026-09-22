#!/bin/bash
# Shared registration logic for install.sh and shunt-update.
#
# Keeping this in one place avoids the two scripts drifting apart (they used to
# duplicate the bin/skill/hook registration verbatim).

# Link the CLI binaries into ~/.local/bin (symlink, falling back to a copy).
shunt_link_binaries() {
  local repo="$1"
  local bin_dir="${HOME}/.local/bin"
  mkdir -p "$bin_dir"
  local bin_script target
  for bin_script in bulk-read code-write shunt-update shunt-local task-exec; do
    target="$repo/scripts/$bin_script"
    if [ -f "$target" ]; then
      chmod +x "$target"
      ln -sf "$target" "$bin_dir/$bin_script" 2>/dev/null || cp -f "$target" "$bin_dir/$bin_script"
      echo "Linked binary '$bin_script' -> $bin_dir/$bin_script"
    fi
  done
}

# Copy skills into ~/.agents/skills (so realpath stays inside ~/.agents/).
shunt_copy_skills() {
  local repo="$1"
  local skills_dir="${HOME}/.agents/skills"
  mkdir -p "$skills_dir"
  local skill skill_name
  for skill in "$repo"/skills/*; do
    if [ -d "$skill" ]; then
      skill_name="$(basename "$skill")"
      rm -rf "$skills_dir/$skill_name"
      cp -r "$skill" "$skills_dir/$skill_name"
      echo "Installed skill '$skill_name' -> $skills_dir/$skill_name"
    fi
  done
}

# Install the OpenCode plugin when OpenCode is present.
shunt_install_opencode_plugin() {
  local repo="$1"
  local config_dir="${HOME}/.config/opencode"
  local plugins_dir="$config_dir/plugins"
  if [ -d "$config_dir" ] || command -v opencode >/dev/null 2>&1; then
    mkdir -p "$plugins_dir"
    chmod 700 "$plugins_dir" 2>/dev/null || true
    cp "$repo/plugins/opencode/shunt-local.ts" "$plugins_dir/shunt-local.ts"
    chmod 600 "$plugins_dir/shunt-local.ts" 2>/dev/null || true
    echo "Installed OpenCode native plugin -> $plugins_dir/shunt-local.ts"
  fi
}

# Register the repository as trusted in Antigravity, only when it is safely
# owned. A trusted directory is executed by the agent on every tool call.
shunt_trust_repo() {
  local repo="$1"
  local trusted_file="${HOME}/.gemini/trustedFolders.json"
  local install_root_file="${HOME}/.config/shunt-local/install_root"
  [ -d "${HOME}/.gemini" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local owner
  owner=$(stat -c '%u' "$repo" 2>/dev/null || stat -f '%u' "$repo" 2>/dev/null || echo "")
  if [ -n "$owner" ] && [ "$owner" != "$(id -u)" ]; then
    echo "⚠️  Not registering $repo as trusted: it is owned by uid $owner (not you)." >&2
    return 0
  fi
  if [ -n "$(find "$repo" -maxdepth 0 \( -perm -0020 -o -perm -0002 \) 2>/dev/null)" ]; then
    echo "⚠️  Not registering $repo as trusted: it is writable by group/other." >&2
    echo "   Fix with: chmod go-w \"$repo\"" >&2
    return 0
  fi

  [ -f "$trusted_file" ] || echo "{}" > "$trusted_file"
  local tmp
  tmp=$(umask 077 && mktemp) || return 1
  jq --arg dir "$repo" '. + {($dir): "TRUST_FOLDER"}' "$trusted_file" > "$tmp" && mv "$tmp" "$trusted_file"
  mkdir -p "$(dirname "$install_root_file")"
  printf '%s' "$repo" > "$install_root_file"
  chmod 600 "$install_root_file" 2>/dev/null || true
  echo "Ensured $repo is trusted in $trusted_file"
}

# Register Antigravity PreToolUse hooks in ~/.gemini/config/hooks.json.
shunt_register_antigravity_hooks() {
  local repo="$1"
  local config_dir="${HOME}/.gemini/config"
  local hooks_file="$config_dir/hooks.json"
  local guard="$repo/hooks/shunt_guard.py"
  if [ ! -d "$config_dir" ] && ! command -v agy >/dev/null 2>&1; then
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "⚠️  jq is required to register Antigravity hooks; skipping." >&2
    return 0
  fi
  mkdir -p "$config_dir"
  [ -f "$hooks_file" ] || echo "{}" > "$hooks_file"
  local tmp
  tmp=$(umask 077 && mktemp) || return 1
  jq \
    --arg read_hook "python3 \"$guard\" --kind read" \
    --arg bash_hook "python3 \"$guard\" --kind bash" \
    --arg write_hook "python3 \"$guard\" --kind write" \
    --arg grep_hook "python3 \"$guard\" --kind grep" \
    '. + {
      "shunt-local": {
        "PreToolUse": [
          {"matcher": "view_file", "hooks": [{"type": "command", "command": $read_hook}]},
          {"matcher": "run_command", "hooks": [{"type": "command", "command": $bash_hook}]},
          {"matcher": "write_to_file|replace_file_content|multi_replace_file_content", "hooks": [{"type": "command", "command": $write_hook}]},
          {"matcher": "grep_search", "hooks": [{"type": "command", "command": $grep_hook}]}
        ]
      }
    }' "$hooks_file" > "$tmp" && mv "$tmp" "$hooks_file"
  echo "Registered PreToolUse hooks in $hooks_file"
}

# Register Cursor native hooks in ~/.cursor/hooks.json.
shunt_register_cursor_hooks() {
  local repo="$1"
  local cursor_dir="${HOME}/.cursor"
  local cursor_file="$cursor_dir/hooks.json"
  local guard="$repo/hooks/shunt_guard.py"
  if [ ! -d "$cursor_dir" ] && ! command -v cursor >/dev/null 2>&1; then
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "⚠️  jq is required to register Cursor hooks; skipping." >&2
    return 0
  fi
  mkdir -p "$cursor_dir"
  [ -f "$cursor_file" ] || echo '{"version": 1, "hooks": {}}' > "$cursor_file"
  local tmp
  tmp=$(umask 077 && mktemp) || return 1
  jq \
    --arg read_hook "python3 \"$guard\" --harness cursor --kind read" \
    --arg shell_hook "python3 \"$guard\" --harness cursor --kind bash" \
    --arg write_hook "python3 \"$guard\" --harness cursor --kind write" \
    --arg grep_hook "python3 \"$guard\" --harness cursor --kind grep" \
    '.version = 1
     | .hooks = (.hooks // {})
     | .hooks.preToolUse = ((.hooks.preToolUse // []) | map(select((.command // "") | test("shunt_guard.py") | not)))
     | .hooks.preToolUse += [
         {"matcher": "Read", "command": $read_hook},
         {"matcher": "Shell", "command": $shell_hook},
         {"matcher": "Write", "command": $write_hook},
         {"matcher": "Grep", "command": $grep_hook}
       ]
     | .hooks.beforeReadFile = ((.hooks.beforeReadFile // []) | map(select((.command // "") | test("shunt_guard.py") | not)))
     | .hooks.beforeReadFile += [ {"matcher": "Read", "command": $read_hook} ]' \
    "$cursor_file" > "$tmp" && mv "$tmp" "$cursor_file"
  chmod 600 "$cursor_file" 2>/dev/null || true
  echo "Registered Cursor hooks in $cursor_file"
}

# Remove the Antigravity hooks this project added.
shunt_unregister_antigravity_hooks() {
  local hooks_file="${HOME}/.gemini/config/hooks.json"
  [ -f "$hooks_file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local tmp
  tmp=$(umask 077 && mktemp) || return 1
  jq 'del(."shunt-local")' "$hooks_file" > "$tmp" && mv "$tmp" "$hooks_file"
  echo "Removed hooks from $hooks_file"
}

# Remove the trusted-folder entry recorded at install time.
shunt_untrust_repo() {
  local install_root_file="${HOME}/.config/shunt-local/install_root"
  local trusted_file="${HOME}/.gemini/trustedFolders.json"
  [ -f "$install_root_file" ] || return 0
  [ -f "$trusted_file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local recorded_root
  recorded_root=$(cat "$install_root_file" 2>/dev/null || true)
  [ -n "$recorded_root" ] || return 0
  local tmp
  tmp=$(umask 077 && mktemp) || return 1
  jq --arg dir "$recorded_root" 'del(.[$dir])' "$trusted_file" > "$tmp" && mv "$tmp" "$trusted_file"
  echo "Removed trust entry for $recorded_root from $trusted_file"
}

# Remove the CLI binaries this project linked.
shunt_unlink_binaries() {
  local bin_dir="${HOME}/.local/bin"
  local bin_script
  for bin_script in bulk-read code-write shunt-update shunt-local task-exec; do
    rm -f "$bin_dir/$bin_script"
  done
}

# Remove the skills this project installed.
shunt_remove_skills() {
  local skills_dir="${HOME}/.agents/skills"
  rm -rf "$skills_dir/bulk-reader" "$skills_dir/code-writer" "$skills_dir/subtask-worker"
}

# Remove the OpenCode plugin this project installed.
shunt_remove_opencode_plugin() {
  rm -f "${HOME}/.config/opencode/plugins/shunt-local.ts"
}

# Remove the Cursor hooks this project added.
shunt_unregister_cursor_hooks() {
  local cursor_file="${HOME}/.cursor/hooks.json"
  [ -f "$cursor_file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local tmp
  tmp=$(umask 077 && mktemp) || return 1
  jq '.hooks.preToolUse = ((.hooks.preToolUse // []) | map(select((.command // "") | test("shunt_guard.py|check-file-size|check-bash-read") | not)))
      | .hooks.beforeReadFile = ((.hooks.beforeReadFile // []) | map(select((.command // "") | test("shunt_guard.py") | not)))' \
    "$cursor_file" > "$tmp" && mv "$tmp" "$cursor_file"
}
