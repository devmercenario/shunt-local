#!/bin/bash
# Sandbox evals for scripts/lib/local-llm.sh command execution.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASSED=0
FAILED=0
check() {
  local name="$1" expected="$2" actual="$3" desc="$4"
  if [ "$expected" = "$actual" ]; then
    printf "  \033[32mPASS\033[0m  %-28s %s\n" "$name" "$desc"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-28s expected=[%s] got=[%s]\n" "$name" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

echo "Sandbox Evals"
echo "────────────────────────────────────────────────────────────────"

mkdir -p "$WORKDIR/bin" "$WORKDIR/home" "$WORKDIR/cwd"
cd "$WORKDIR/cwd"

# Mock bwrap: logs argv and succeeds (also satisfies the availability probe).
cat > "$WORKDIR/bin/bwrap" <<MOCK
#!/bin/bash
printf '%s\n' "\$*" >> "$WORKDIR/bwrap.args"
exit 0
MOCK
chmod +x "$WORKDIR/bin/bwrap"

source_lib() {
  # shellcheck disable=SC1091
  HOME="$WORKDIR/home" . "$PLUGIN_DIR/scripts/lib/local-llm.sh" >/dev/null 2>&1
}

backend() { # wanted -> prints backend
  ( HOME="$WORKDIR/home" PATH="$WORKDIR/bin:$PATH" SHUNT_SANDBOX="$1" \
      bash -c ". '$PLUGIN_DIR/scripts/lib/local-llm.sh' >/dev/null 2>&1; shunt_sandbox_backend" )
}

check "none-backend" "none" "$(backend none)" "SHUNT_SANDBOX=none selects none"
check "bwrap-backend" "bwrap" "$(backend bwrap)" "SHUNT_SANDBOX=bwrap selects bwrap"
check "invalid-backend" "" "$(backend nonsense 2>/dev/null || true)" "invalid backend is rejected"

# Mocked bwrap argv inspection.
: > "$WORKDIR/bwrap.args"
( cd "$WORKDIR/cwd" && HOME="$WORKDIR/home" PATH="$WORKDIR/bin:$PATH" SHUNT_SANDBOX=bwrap \
    bash -c ". '$PLUGIN_DIR/scripts/lib/local-llm.sh' >/dev/null 2>&1; shunt_run_command 'echo hi' argv" >/dev/null 2>&1 )
args=$(cat "$WORKDIR/bwrap.args")
check "bwrap-unshare-net" "yes" "$(printf '%s' "$args" | grep -q -- '--unshare-net' && echo yes || echo no)" "network is unshared by default"
check "bwrap-bind-cwd" "yes" "$(printf '%s' "$args" | grep -q -- "--bind $WORKDIR/cwd $WORKDIR/cwd" && echo yes || echo no)" "CWD is bind-mounted read-write"
check "bwrap-passthrough" "yes" "$(printf '%s' "$args" | grep -q -- '-- echo hi' && echo yes || echo no)" "command is passed through"

: > "$WORKDIR/bwrap.args"
( cd "$WORKDIR/cwd" && HOME="$WORKDIR/home" PATH="$WORKDIR/bin:$PATH" SHUNT_SANDBOX=bwrap SHUNT_SANDBOX_NETWORK=true \
    bash -c ". '$PLUGIN_DIR/scripts/lib/local-llm.sh' >/dev/null 2>&1; shunt_run_command 'echo hi' argv" >/dev/null 2>&1 )
args=$(cat "$WORKDIR/bwrap.args")
check "bwrap-network-optin" "no" "$(printf '%s' "$args" | grep -q -- '--unshare-net' && echo yes || echo no)" "SHUNT_SANDBOX_NETWORK=true keeps network"

# docker requires an image.
val=$( ( cd "$WORKDIR/cwd" && HOME="$WORKDIR/home" SHUNT_SANDBOX=docker \
    bash -c ". '$PLUGIN_DIR/scripts/lib/local-llm.sh' >/dev/null 2>&1; shunt_run_command 'echo hi' argv" ) 2>&1 || true )
check "docker-requires-image" "yes" "$(printf '%s' "$val" | grep -q 'SHUNT_SANDBOX_IMAGE is required' && echo yes || echo no)" "docker backend without image errors"

# STRICT refuses when no sandbox is available.
rc=0
( cd "$WORKDIR/cwd" && HOME="$WORKDIR/home" SHUNT_SANDBOX=none SHUNT_SANDBOX_STRICT=true \
    bash -c ". '$PLUGIN_DIR/scripts/lib/local-llm.sh' >/dev/null 2>&1; shunt_run_command 'echo hi' argv" ) >/dev/null 2>&1 || rc=$?
check "strict-refuses-none" "1" "$rc" "SHUNT_SANDBOX_STRICT refuses unsandboxed execution"

# Real bwrap end-to-end when available.
if command -v bwrap >/dev/null 2>&1 && bwrap --ro-bind / / --dev /dev --proc /proc -- /bin/true >/dev/null 2>&1; then
  ( cd "$WORKDIR/cwd" && HOME="$WORKDIR/home" SHUNT_SANDBOX=bwrap \
      bash -c ". '$PLUGIN_DIR/scripts/lib/local-llm.sh' >/dev/null 2>&1; shunt_run_command 'touch inside.txt' argv" ) >/dev/null 2>&1 || true
  check "bwrap-writes-cwd" "yes" "$([ -f "$WORKDIR/cwd/inside.txt" ] && echo yes || echo no)" "sandboxed command can write to the CWD"

  ( cd "$WORKDIR/cwd" && HOME="$WORKDIR/home" SHUNT_SANDBOX=bwrap \
      bash -c ". '$PLUGIN_DIR/scripts/lib/local-llm.sh' >/dev/null 2>&1; shunt_run_command 'touch /shunt-sandbox-escape-marker' argv" ) >/dev/null 2>&1 || true
  check "bwrap-fs-isolated" "no" "$([ -e /shunt-sandbox-escape-marker ] && echo yes || echo no)" "sandboxed command cannot write outside the bind"
  rm -f /shunt-sandbox-escape-marker
else
  printf "  \033[33mSKIP\033[0m  %-28s bwrap not usable here\n" "bwrap-e2e"
fi

echo ""
echo "## $PASSED $FAILED"
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
