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
# shellcheck source=../scripts/lib/register.sh
. "$PLUGIN_DIR/scripts/lib/register.sh"

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

# Stray bytecode restoration must be wired into both pull paths (the call is
# indented; the column-0 definition is excluded).
check "update-restores-artifacts" "yes" \
  "$(grep -qE '^[[:space:]]+shunt_restore_stray_artifacts ' "$PLUGIN_DIR/scripts/shunt-update" && echo yes || echo no)" \
  "shunt-update restores stray bytecode before pulling"
check "install-sync-restores-artifacts" "yes" \
  "$(grep -qE '^[[:space:]]+shunt_restore_stray_artifacts ' "$PLUGIN_DIR/scripts/lib/register.sh" && echo yes || echo no)" \
  "install.sh sync restores stray bytecode before pulling"

# Stray tracked bytecode (regenerated at runtime) must be restored before a
# pull, without ever touching source files.
ARTIFACTS="$WORKDIR/artifacts"
mkdir -p "$ARTIFACTS/scripts/lib/__pycache__"
(
  cd "$ARTIFACTS"
  git init -q .
  git config user.email eval@example.com
  git config user.name eval
  git config commit.gpgsign false
  printf 'source\n' > keep.txt
  printf 'committed\n' > scripts/lib/__pycache__/paths.pyc
  printf 'committed\n' > loose.pyc
  git add -f -A
  git commit -qm init
  printf 'modified\n' > keep.txt
  printf 'regenerated\n' > scripts/lib/__pycache__/paths.pyc
  printf 'regenerated\n' > loose.pyc
) >/dev/null 2>&1

shunt_restore_stray_artifacts "$ARTIFACTS" >/dev/null 2>&1 || true
check "restore-py-cache" "0" \
  "$(git -C "$ARTIFACTS" diff --name-only -- scripts/lib/__pycache__/paths.pyc | wc -l | tr -d ' ')" \
  "__pycache__ bytecode restored before pull"
check "restore-loose-bytecode" "0" \
  "$(git -C "$ARTIFACTS" diff --name-only -- loose.pyc | wc -l | tr -d ' ')" \
  "loose .pyc restored before pull"
check "restore-keeps-source" "1" \
  "$(git -C "$ARTIFACTS" diff --name-only -- keep.txt | wc -l | tr -d ' ')" \
  "non-bytecode changes left untouched"
check "restore-outside-repo" "0" \
  "$(shunt_restore_stray_artifacts "$WORKDIR/not-a-repo" >/dev/null 2>&1; echo $?)" \
  "restore is a no-op outside a git work tree"

echo ""
echo "## $PASSED $FAILED"
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
