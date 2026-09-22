#!/bin/bash
# Test suite for OpenCode TypeScript plugin (plugins/opencode/shunt-local.ts)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
node "$SCRIPT_DIR/test-opencode-plugin.mjs"
