#!/bin/bash
# Installer for shunt-local (Antigravity, Claude Code, Codex, Cursor, OpenCode).
# Registration lives in scripts/lib/register.sh (shared with shunt-update).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Curl bootstrap: when this script is piped from the web (`curl -fsSL ... | bash`)
# there is no repository alongside it, so download the latest snapshot into a
# persistent install root and re-run the real installer from there. Clones run
# this file directly, where scripts/lib/register.sh exists and this is skipped.
if [ ! -f "$SCRIPT_DIR/scripts/lib/register.sh" ]; then
  INSTALL_ROOT="${SHUNT_INSTALL_DIR:-$HOME/.local/share/shunt-local}"
  DOWNLOAD_URL="${SHUNT_DOWNLOAD_URL:-https://codeload.github.com/devmercenario/shunt-local/tar.gz/refs/heads/main}"
  echo "shunt-local installer (curl): downloading the latest snapshot..."
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  if ! curl -fsSL "$DOWNLOAD_URL" -o "$tmp/snapshot.tar.gz"; then
    echo "Error: failed to download $DOWNLOAD_URL" >&2
    exit 1
  fi
  mkdir -p "$tmp/extract"
  if ! tar -xzf "$tmp/snapshot.tar.gz" -C "$tmp/extract" --strip-components=1; then
    echo "Error: failed to extract the downloaded archive" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$INSTALL_ROOT")"
  rm -rf "$INSTALL_ROOT"
  mv "$tmp/extract" "$INSTALL_ROOT"
  trap - EXIT
  rm -rf "$tmp"
  echo "Installed snapshot to $INSTALL_ROOT"
  exec bash "$INSTALL_ROOT/install.sh" "$@"
fi

# shellcheck source=scripts/lib/register.sh
. "$SCRIPT_DIR/scripts/lib/register.sh"
# shellcheck source=scripts/lib/update-verify.sh
. "$SCRIPT_DIR/scripts/lib/update-verify.sh"

CONFIG_DIR="${HOME}/.config/shunt-local"
BIN_DIR="${HOME}/.local/bin"

echo "Installing shunt-local..."

# 1. Preflight dependencies
for cmd in jq curl python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: missing required dependency: $cmd" >&2
    echo "Please install $cmd using your package manager." >&2
    exit 1
  fi
done

# 2. Sync the install clone with origin/main (opt out: SHUNT_NO_PULL=1).
shunt_sync_install_source "$SCRIPT_DIR"

# 3. User configuration directory
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR" 2>/dev/null || true
if [ ! -f "$CONFIG_DIR/config.json" ]; then
  cp "$SCRIPT_DIR/config.example.json" "$CONFIG_DIR/config.json"
  echo "Created default config at $CONFIG_DIR/config.json"
else
  echo "Found existing config at $CONFIG_DIR/config.json"
fi
chmod 600 "$CONFIG_DIR/config.json" 2>/dev/null || true

# 4. Binaries and skills
shunt_link_binaries "$SCRIPT_DIR"
shunt_copy_skills "$SCRIPT_DIR"

# 5. Antigravity trust + hooks (only when the repository is safely owned)
shunt_trust_repo "$SCRIPT_DIR"
shunt_register_antigravity_hooks "$SCRIPT_DIR"

# 6. Harness plugin registration
if command -v agy >/dev/null 2>&1; then
  echo "Registering with Antigravity CLI (agy)..."
  agy plugin install "$SCRIPT_DIR" 2>/dev/null || true
fi
if command -v claude >/dev/null 2>&1; then
  echo "Registering with Claude Code (claude)..."
  claude plugin install "$SCRIPT_DIR" 2>/dev/null || claude plugin add "$SCRIPT_DIR" 2>/dev/null || true
fi
shunt_install_opencode_plugin "$SCRIPT_DIR"
shunt_register_cursor_hooks "$SCRIPT_DIR"

# 7. PATH hint
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo ""
    echo "⚠️  NOTE: $BIN_DIR is not currently in your \$PATH."
    echo "   Add this to your shell config (~/.zshrc or ~/.bashrc):"
    echo "   export PATH=\"\$HOME/.local/bin:\$PATH\""
    ;;
esac

echo ""
echo "Installation complete!"
echo "Configuration: $CONFIG_DIR/config.json"
echo "To verify tests, run: bash $SCRIPT_DIR/evals/run.sh"
