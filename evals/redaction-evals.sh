#!/bin/bash
# Redaction, read-confinement and key resolution evals.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$PLUGIN_DIR/scripts/lib/local-llm.sh"

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

echo "Redaction & Confinement Evals"
echo "────────────────────────────────────────────────────────────────"

mkdir -p "$WORKDIR/bin" "$WORKDIR/home" "$WORKDIR/work"
cd "$WORKDIR/work"

# Mock curl: logs argv and copies the outbound payload so tests can inspect it.
cat > "$WORKDIR/bin/curl" <<MOCK
#!/bin/bash
printf '%s\n' "\$*" >> "\${CURL_ARG_LOG:-/dev/null}"
for a in "\$@"; do
  case "\$a" in
    @*) cp "\${a#@}" "\${PAYLOAD_COPY:-/dev/null}" 2>/dev/null || true ;;
  esac
done
if [[ "\$*" == *"/v1/models"* ]]; then echo '{"data": []}'; exit 0; fi
printf '%s' '{"choices":[{"message":{"role":"assistant","content":"ok"}}]}'
MOCK
chmod +x "$WORKDIR/bin/curl"

# --- redact.py unit behaviour ---
redacted=$(printf 'aws=AKIAIOSFODNN7EXAMPLE\npassword = hunter2hunter2\n' | python3 "$PLUGIN_DIR/scripts/lib/redact.py" 2>/dev/null)
check "redact-aws" "no" "$(printf '%s' "$redacted" | grep -q 'AKIAIOSFODNN7EXAMPLE' && echo yes || echo no)" "AWS access key redacted"
check "redact-assignment" "no" "$(printf '%s' "$redacted" | grep -q 'hunter2hunter2' && echo yes || echo no)" "assigned secret redacted"
check "redact-marker" "yes" "$(printf '%s' "$redacted" | grep -qi 'REDACTED' && echo yes || echo no)" "redaction marker present"

# --- shunt_redact_file + block mode ---
echo "token: ghp_abcdefghijklmnopqrstuvwxyz0123456789" > "$WORKDIR/work/secret.txt"
( HOME="$WORKDIR/home" bash -c ". '$LIB' >/dev/null 2>&1; SHUNT_REDACT_SECRETS=true; shunt_redact_file '$WORKDIR/work/secret.txt' '$WORKDIR/work/out.txt'" ) 2>/dev/null
check "redact-file" "no" "$(grep -q 'ghp_abcdef' "$WORKDIR/work/out.txt" && echo yes || echo no)" "shunt_redact_file removes the secret"
rc=0
( HOME="$WORKDIR/home" SHUNT_BLOCK_ON_SECRETS=true bash -c ". '$LIB' >/dev/null 2>&1; shunt_redact_file '$WORKDIR/work/secret.txt' '$WORKDIR/work/out2.txt'" ) >/dev/null 2>&1 || rc=$?
check "block-on-secrets" "1" "$rc" "SHUNT_BLOCK_ON_SECRETS refuses the payload"

# --- key resolution ---
key=$( HOME="$WORKDIR/home" SHUNT_API_KEY_CMD='printf sk-from-keyring' \
  bash -c ". '$LIB' >/dev/null 2>&1; printf '%s' \"\$SHUNT_API_KEY\"" )
check "key-from-cmd" "sk-from-keyring" "$key" "SHUNT_API_KEY_CMD resolves the key"
printf 'sk-from-file' > "$WORKDIR/home/keyfile"
key=$( HOME="$WORKDIR/home" SHUNT_API_KEY_FILE="$WORKDIR/home/keyfile" \
  bash -c ". '$LIB' >/dev/null 2>&1; printf '%s' \"\$SHUNT_API_KEY\"" )
check "key-from-file" "sk-from-file" "$key" "SHUNT_API_KEY_FILE resolves the key"

# --- read confinement ---
printf 'outside\n' > "$WORKDIR/outside.txt"
rc=0
( cd "$WORKDIR/work" && HOME="$WORKDIR/home" PATH="$WORKDIR/bin:$PATH" \
    "$PLUGIN_DIR/scripts/bulk-read" --question q --paths "$WORKDIR/outside.txt" ) >/dev/null 2>&1 || rc=$?
check "bulk-read-refuse-outside" "1" "$rc" "bulk-read refuses a path outside the CWD"

rc=0
( cd "$WORKDIR/work" && HOME="$WORKDIR/home" PATH="$WORKDIR/bin:$PATH" \
    "$PLUGIN_DIR/scripts/code-write" --spec x --reference "$WORKDIR/outside.txt" --target "$WORKDIR/work/o.py" ) >/dev/null 2>&1 || rc=$?
check "code-write-refuse-outside" "1" "$rc" "code-write refuses a reference outside the CWD"

rc=0
( cd "$WORKDIR/work" && HOME="$WORKDIR/home" PATH="$WORKDIR/bin:$PATH" SHUNT_ALLOW_READS_OUTSIDE_CWD=true \
    "$PLUGIN_DIR/scripts/bulk-read" --question q --paths "$WORKDIR/outside.txt" ) >/dev/null 2>&1 || rc=$?
check "read-optin" "0" "$rc" "SHUNT_ALLOW_READS_OUTSIDE_CWD allows the read"

# --- end-to-end: secret never reaches the endpoint ---
printf 'api_key = AKIAIOSFODNN7EXAMPLE\n' > "$WORKDIR/work/leak.txt"
( cd "$WORKDIR/work" && HOME="$WORKDIR/home" PATH="$WORKDIR/bin:$PATH" \
    CURL_ARG_LOG="$WORKDIR/curl.log" PAYLOAD_COPY="$WORKDIR/payload.json" \
    "$PLUGIN_DIR/scripts/bulk-read" --question q --paths "$WORKDIR/work/leak.txt" ) >/dev/null 2>&1 || true
check "e2e-secret-redacted" "no" "$(grep -q 'AKIAIOSFODNN7EXAMPLE' "$WORKDIR/payload.json" 2>/dev/null && echo yes || echo no)" "secret absent from the outbound payload"

# --- shared sensitive-name detection (canonical file) ---
libcheck() { HOME="$WORKDIR/home" bash -c ". '$LIB' >/dev/null 2>&1; $1" >/dev/null 2>&1 && echo 0 || echo 1; }
check "sensitive-name-git" "0" "$(libcheck 'shunt_is_sensitive_name .git')" "exact sensitive name matches"
check "sensitive-name-env-prefix" "0" "$(libcheck 'shunt_is_sensitive_name .env.staging')" ".env.* prefix matches"
check "sensitive-name-normal" "1" "$(libcheck 'shunt_is_sensitive_name module.py')" "normal name does not match"
check "sensitive-path-dir" "0" "$(libcheck 'shunt_path_sensitive a/.git/config')" "sensitive path component detected"
check "sensitive-path-ok" "1" "$(libcheck 'shunt_path_sensitive src/module.py')" "normal path allowed"
check "list-contains-hit" "0" "$(libcheck $'shunt_list_contains b "a\nb\nc"')" "list membership hit"
check "list-contains-miss" "1" "$(libcheck $'shunt_list_contains x "a\nb\nc"')" "list membership miss"
# Regex metacharacters in a name must not be interpreted (no =~ regex bug).
check "list-regex-safe" "1" "$(libcheck $'shunt_list_contains "a.c" "abc\nxyz"')" "membership is literal, not regex"

echo ""
echo "## $PASSED $FAILED"
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
