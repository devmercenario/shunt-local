#!/bin/bash
# Evals for scripts/task-exec: TaskContract parsing, context packing, self-correction loop, and rollback.

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
    printf "  \033[32mPASS\033[0m  %-32s %s\n" "$name" "$desc"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-32s expected=[%s] got=[%s]\n" "$name" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

echo "Subtask Worker Evals (scripts/task-exec)"
echo "────────────────────────────────────────────────────────────────"

# Test 1: Capability A - Spec file parsing & single-shot success
(
  export SHUNT_CONFIG_PATH="$WORKDIR/dummy-cfg.json"
  cat << 'JSON' > "$SHUNT_CONFIG_PATH"
{
  "enabled": true,
  "endpoint": "http://127.0.0.1:8080/v1/chat/completions",
  "model": "Qwen/Qwen2.5-Coder-32B"
}
JSON

  TARGET_FILE="$WORKDIR/generated_module.py"
  TEST_FILE="$WORKDIR/test_module.py"

  cat << 'PY' > "$TEST_FILE"
import sys
try:
    import generated_module
    assert generated_module.add(2, 3) == 5
    print("ALL TESTS PASSED")
    sys.exit(0)
except Exception as e:
    print(f"FAILED: {e}", file=sys.stderr)
    sys.exit(1)
PY

  # Mock curl to return working python code on attempt 1
  mock_bin="$WORKDIR/bin"
  mkdir -p "$mock_bin"
  cat << 'MOCK' > "$mock_bin/curl"
#!/bin/bash
if [[ "$*" == *"/v1/models"* ]]; then
  echo '{"data": [{"id": "Qwen/Qwen2.5-Coder-32B"}]}'
  exit 0
fi

cat << 'JSON'
{
  "choices": [
    {
      "message": {
        "role": "assistant",
        "content": "```generated_module.py\ndef add(a, b):\n    return a + b\n```"
      }
    }
  ]
}
JSON
MOCK
  chmod +x "$mock_bin/curl"

  SPEC_FILE="$WORKDIR/task.json"
  cat << JSON > "$SPEC_FILE"
{
  "task_id": "test-task-1",
  "instruction": "Implement add(a, b) function",
  "target_files": ["$TARGET_FILE"],
  "verification_command": "python3 -B $TEST_FILE"
}
JSON

  PATH="$mock_bin:$PATH" PYTHONPATH="$WORKDIR" "$PLUGIN_DIR/scripts/task-exec" --spec-file "$SPEC_FILE" > "$WORKDIR/out1.json"
)

status1=$(jq -r '.status' "$WORKDIR/out1.json")
attempts1=$(jq -r '.attempts' "$WORKDIR/out1.json")
check "exec-success-status" "success" "$status1" "single-shot success returns status success"
check "exec-success-attempts" "1" "$attempts1" "completed on attempt 1"

# Test 2: Capability C - Self-Correction Loop (Attempt 1 fails, Attempt 2 succeeds)
(
  export SHUNT_CONFIG_PATH="$WORKDIR/dummy-cfg.json"
  TARGET_FILE="$WORKDIR/corrected_module.py"
  TEST_FILE="$WORKDIR/test_corrected.py"

  cat << 'PY' > "$TEST_FILE"
import sys
try:
    import corrected_module
    assert corrected_module.multiply(3, 4) == 12
    print("MULTIPLICATION PASSED")
    sys.exit(0)
except Exception as e:
    print(f"ASSERTION_ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PY

  mock_bin="$WORKDIR/bin2"
  mkdir -p "$mock_bin"
  call_count_file="$WORKDIR/call_count.txt"
  echo "0" > "$call_count_file"

  cat << 'MOCK' > "$mock_bin/curl"
#!/bin/bash
if [[ "$*" == *"/v1/models"* ]]; then
  echo '{"data": [{"id": "Qwen/Qwen2.5-Coder-32B"}]}'
  exit 0
fi

count_file="${CALL_COUNT_FILE:-/tmp/call_count.txt}"
calls=$(cat "$count_file" 2>/dev/null || echo 0)
calls=$((calls + 1))
echo "$calls" > "$count_file"

if [ "$calls" -eq 1 ]; then
  # First call returns buggy code (multiply returns addition)
  cat << 'JSON'
{
  "choices": [
    {
      "message": {
        "role": "assistant",
        "content": "```corrected_module.py\ndef multiply(a, b):\n    return a + b\n```"
      }
    }
  ]
}
JSON
else
  # Second call fixes the bug
  cat << 'JSON'
{
  "choices": [
    {
      "message": {
        "role": "assistant",
        "content": "```corrected_module.py\ndef multiply(a, b):\n    return a * b\n```"
      }
    }
  ]
}
JSON
fi
MOCK
  chmod +x "$mock_bin/curl"

  CALL_COUNT_FILE="$call_count_file" PATH="$mock_bin:$PATH" PYTHONPATH="$WORKDIR" "$PLUGIN_DIR/scripts/task-exec" \
    --instruction "Implement multiply(a, b)" \
    --files "$TARGET_FILE" \
    --test-cmd "python3 -B $TEST_FILE" \
    --max-retries 3 > "$WORKDIR/out2.json"
)

status2=$(jq -r '.status' "$WORKDIR/out2.json")
attempts2=$(jq -r '.attempts' "$WORKDIR/out2.json")
check "self-correction-status" "success" "$status2" "succeeds after self-correction"
check "self-correction-attempts" "2" "$attempts2" "took 2 attempts to fix the bug"

# Test 3: Capability C & Rollback - Retries exhausted triggers rollback command
(
  export SHUNT_CONFIG_PATH="$WORKDIR/dummy-cfg.json"
  TARGET_FILE="$WORKDIR/failing_module.py"
  ROLLBACK_FLAG="$WORKDIR/rolled_back.flag"

  mock_bin="$WORKDIR/bin3"
  mkdir -p "$mock_bin"
  cat << 'MOCK' > "$mock_bin/curl"
#!/bin/bash
if [[ "$*" == *"/v1/models"* ]]; then
  echo '{"data": [{"id": "Qwen/Qwen2.5-Coder-32B"}]}'
  exit 0
fi

cat << 'JSON'
{
  "choices": [
    {
      "message": {
        "role": "assistant",
        "content": "```failing_module.py\ndef bad(): pass\n```"
      }
    }
  ]
}
JSON
MOCK
  chmod +x "$mock_bin/curl"

  set +e
  PATH="$mock_bin:$PATH" "$PLUGIN_DIR/scripts/task-exec" \
    --instruction "Will fail" \
    --files "$TARGET_FILE" \
    --test-cmd "false" \
    --rollback-cmd "touch $ROLLBACK_FLAG" \
    --max-retries 2 > "$WORKDIR/out3.json" 2>&1
  rc3=$?
  set -e

  check "rollback-exit-code" "1" "$rc3" "returns exit code 1 when all retries fail"
)

status3=$(jq -r '.status' "$WORKDIR/out3.json")
rolled_back3=$(jq -r '.rolled_back' "$WORKDIR/out3.json")
check "failed-status" "failed" "$status3" "payload status is failed"
check "rollback-executed" "true" "$rolled_back3" "rollback_command was triggered"
[ -f "$WORKDIR/rolled_back.flag" ] && rb_flag="exists" || rb_flag="missing"
check "rollback-flag-file" "exists" "$rb_flag" "rollback command created flag file"

echo ""
echo "## $PASSED $FAILED"
echo "Results: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
