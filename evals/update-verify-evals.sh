#!/bin/bash
# Update-verification evals: trusted-remote hostname check and signature checks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$PLUGIN_DIR/scripts/lib/update-verify.sh"

WORKDIR="$(mktemp -d)"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
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

echo "Update Verification Evals"
echo "────────────────────────────────────────────────────────────────"

# shellcheck disable=SC1090
. "$LIB"

trusted() { shunt_remote_is_trusted "$1" && echo yes || echo no; }

check "trust-github" "yes" "$(trusted 'https://github.com/o/r')" "https GitHub accepted"
check "trust-gitlab" "yes" "$(trusted 'https://gitlab.com/o/r')" "https GitLab accepted"
check "trust-bitbucket" "yes" "$(trusted 'https://bitbucket.org/o/r')" "https Bitbucket accepted"
check "trust-scm-github" "yes" "$(trusted 'git@github.com:o/r.git')" "scp-style git@github accepted"
check "reject-suffix-spoof" "no" "$(trusted 'https://github.com.evil.example/o/r')" "suffix-spoofed host rejected"
check "reject-path-spoof" "no" "$(trusted 'https://evil.example/github.com/o/r')" "path-embedded host rejected"
check "reject-unknown" "no" "$(trusted 'https://evil.example/o/r')" "unknown host rejected"

# Mock git so verify-commit can be forced to fail/succeed.
mkdir -p "$WORKDIR/bin"
cat > "$WORKDIR/bin/git" <<MOCK
#!/bin/bash
if [ "\$1" = "-C" ] && [ "\$3" = "verify-commit" ]; then exit \${MOCK_VERIFY_RC:-1}; fi
exec /usr/bin/git "\$@"
MOCK
chmod +x "$WORKDIR/bin/git"

cat > "$WORKDIR/bin/cosign" <<MOCK
#!/bin/bash
exit \${MOCK_COSIGN_RC:-1}
MOCK
chmod +x "$WORKDIR/bin/cosign"

REPO="$WORKDIR/repo"
mkdir -p "$REPO"
: > "$REPO/SHA256SUMS"; : > "$REPO/SHA256SUMS.sig"; : > "$REPO/SHA256SUMS.pem"

run_verify() { # verify_rc cosign_rc
  ( PATH="$WORKDIR/bin:$PATH" MOCK_VERIFY_RC="$1" MOCK_COSIGN_RC="$2" \
      bash -c ". '$LIB'; shunt_verify_update '$REPO' origin/main" ) >/dev/null 2>&1 \
    && echo ok || echo fail
}

check "signed-commit-ok" "ok" "$(run_verify 0 1)" "signed commit is accepted"
check "unsigned-no-cosign" "fail" "$(run_verify 1 1)" "unsigned commit + failing cosign is rejected"
check "unsigned-cosign-ok" "ok" "$(run_verify 1 0)" "cosign attestation accepted as fallback"
check "no-attestation-files" "fail" \
  "$( ( PATH="$WORKDIR/bin:$PATH" MOCK_VERIFY_RC=1 MOCK_COSIGN_RC=0 bash -c ". '$LIB'; rm -f '$REPO/SHA256SUMS.sig'; shunt_verify_update '$REPO' origin/main" ) >/dev/null 2>&1 && echo ok || echo fail )" \
  "missing signature file is rejected"

# shunt-update must actually invoke verification.
check "update-invokes-verify" "yes" \
  "$(grep -q 'shunt_verify_update' "$PLUGIN_DIR/scripts/shunt-update" && echo yes || echo no)" \
  "shunt-update calls shunt_verify_update"

echo ""
echo "## $PASSED $FAILED"
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
