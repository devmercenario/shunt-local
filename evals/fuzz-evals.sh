#!/bin/bash
# Property-based fuzzing of the command allowlist and endpoint validator.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# The property harness drives bash via a shell protocol; on Windows the MSYS
# base64/encoding round-trip is unreliable. The properties are still covered on
# Linux and macOS, so skip Windows.
if command -v cygpath >/dev/null 2>&1; then
  echo "Fuzz Evals"
  echo "────────────────────────────────────────────────────────────────"
  echo "  SKIP  property fuzzing is skipped on Windows (covered on Linux/macOS)"
  echo ""
  echo "## 0 0"
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

exec python3 "$SCRIPT_DIR/fuzz_validate.py" "$PLUGIN_DIR"
