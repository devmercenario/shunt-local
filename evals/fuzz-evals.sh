#!/bin/bash
# Property-based fuzzing of the command allowlist and endpoint validator.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
exec python3 "$SCRIPT_DIR/fuzz_validate.py" "$PLUGIN_DIR"
