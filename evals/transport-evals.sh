#!/bin/bash
# Transport evals for scripts/lib/local-llm.sh against stubbed HTTP responses.
# No live server required for unit testing.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKDIR="$(mktemp -d)"
CAPTURED_PAYLOAD="$WORKDIR/captured-payload.json"
trap 'rm -rf "$WORKDIR"' EXIT

# Source local-llm library
. "$PLUGIN_DIR/scripts/lib/local-llm.sh"

PASSED=0
FAILED=0

check() {
  local name="$1" expected="$2" actual="$3" desc="$4"
  if [ "$expected" = "$actual" ]; then
    printf "  \033[32mPASS\033[0m  %-32s %s\n" "$name" "$desc"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-32s expected=[%s] got=[%s]\n" "$name" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

message_file="$WORKDIR/message.txt"
printf 'Line 1\nLine 2\n' > "$message_file"

# Test 1: Successful response parsing and payload generation
curl() {
  # Mock curl
  local payload_arg=""
  while [[ $# -gt 0 ]]; do
    if [ "$1" = "--data-binary" ]; then
      payload_arg="${2#@}"
      cp "$payload_arg" "$CAPTURED_PAYLOAD"
      shift 2
    else
      shift
    fi
  done
  cat << 'JSON'
{
  "choices": [
    {
      "message": {
        "role": "assistant",
        "content": "- symbol A: line 10\n- symbol B: line 25"
      }
    }
  ]
}
JSON
}

res=$(shunt_invoke bulk-reader "$message_file")
check "extract-content" "- symbol A: line 10
- symbol B: line 25" "$res" "extracts .choices[0].message.content"

sent_sys=$(jq -r '.messages[0].content' "$CAPTURED_PAYLOAD")
case "$sent_sys" in
  *"precise code analyst"*) check "bulk-reader-system-prompt" "y" "y" "sets bulk-reader system prompt" ;;
  *)                         check "bulk-reader-system-prompt" "y" "n" "sets bulk-reader system prompt" ;;
esac

sent_user=$(jq -r '.messages[1].content' "$CAPTURED_PAYLOAD")
check "message-content-preserved" "Line 1
Line 2" "$sent_user" "preserves user message verbatim"

# Test 2: Code-writer system prompt
res=$(shunt_invoke code-writer "$message_file")
sent_sys=$(jq -r '.messages[0].content' "$CAPTURED_PAYLOAD")
case "$sent_sys" in
  *"generate code files based on a spec"*) check "code-writer-system-prompt" "y" "y" "sets code-writer system prompt" ;;
  *)                                      check "code-writer-system-prompt" "y" "n" "sets code-writer system prompt" ;;
esac

# Test 3: Stripping <think>...</think> reasoning tags
curl() {
  cat << 'JSON'
{
  "choices": [
    {
      "message": {
        "role": "assistant",
        "content": "<think>\nLet me think about this...\nDone thinking.\n</think>\nClean output"
      }
    }
  ]
}
JSON
}
res=$(shunt_invoke bulk-reader "$message_file")
check "strip-thinking-tags" "Clean output" "$res" "strips <think> tags from output"

# Test 4: Server returned an API error
curl() {
  cat << 'JSON'
{
  "error": {
    "message": "CUDA out of memory"
  }
}
JSON
}
out=$(shunt_invoke bulk-reader "$message_file" 2>&1 >/dev/null) && rc=0 || rc=$?
check "api-error-fails" "1" "$rc" "reports error code when API returns error object"
case "$out" in
  *"CUDA out of memory"*) check "api-error-message" "y" "y" "surfaces API error message" ;;
  *)                      check "api-error-message" "y" "n" "surfaces API error message" ;;
esac

# Test 5: Empty message content
curl() {
  cat << 'JSON'
{
  "choices": [{"message": {"content": ""}}]
}
JSON
}
out=$(shunt_invoke bulk-reader "$message_file" 2>&1 >/dev/null) && rc=0 || rc=$?
check "empty-content-fails" "1" "$rc" "fails when response content is empty"

# Test 6: Garbled / Non-JSON output
curl() {
  echo "502 Bad Gateway"
}
out=$(shunt_invoke bulk-reader "$message_file" 2>&1 >/dev/null) && rc=0 || rc=$?
check "garbled-output-fails" "1" "$rc" "fails when response is not JSON"

# Test 7: Connection refused (curl rc 7)
curl() {
  echo "curl: (7) Failed to connect to 127.0.0.1" >&2
  return 7
}
out=$(shunt_invoke bulk-reader "$message_file" 2>&1 >/dev/null) && rc=0 || rc=$?
check "conn-refused-fails" "1" "$rc" "fails with curl error on connection refused"
case "$out" in
  *"could not connect to local LLM"*|"*(curl exit code 7)*"*) check "conn-refused-message" "y" "y" "helpful connection failure hint" ;;
  *)                                                          check "conn-refused-message" "y" "n" "helpful connection failure hint" ;;
esac

# Test 8: Timeout (curl rc 28)
curl() {
  echo "curl: (28) Operation timed out" >&2
  return 28
}
out=$(shunt_invoke bulk-reader "$message_file" 2>&1 >/dev/null) && rc=0 || rc=$?
check "timeout-fails" "1" "$rc" "fails on curl timeout"
case "$out" in
  *"timed out after"*|"*(curl exit code 28)*"*) check "timeout-message" "y" "y" "helpful timeout hint" ;;
  *)                                            check "timeout-message" "y" "n" "helpful timeout hint" ;;
esac

echo "## $PASSED $FAILED"
[ "$FAILED" -gt 0 ] && exit 1
exit 0
