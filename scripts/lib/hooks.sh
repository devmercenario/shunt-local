#!/bin/bash
# PreToolUse decision emitter (harness-specific output formats).
# Sourced by local-llm.sh (do not execute directly).

# Emit a PreToolUse decision in the format the calling harness understands.
#   $1 = "allow" | "deny"
#   $2 = reason (used when denying)
#   $3 = is_antigravity ("true" when the payload contains toolCall)
#   SHUNT_HOOK_HARNESS may force "antigravity" | "claude" | "cursor".
#
# - Antigravity requires an explicit decision field (allow/deny).
# - Cursor native hooks expect {permission:"allow"|"deny", user_message, agent_message}.
# - Claude Code and Codex use hookSpecificOutput.permissionDecision. On the
#   non-blocking path we emit NOTHING: returning permissionDecision "allow"
#   would silently auto-approve the tool call, bypassing the permission prompt.
shunt_emit_pretooluse_decision() {
  local decision="$1" reason="${2:-}" antigravity="${3:-false}"
  local harness="${SHUNT_HOOK_HARNESS:-}"
  if [ -z "$harness" ]; then
    if [ "$antigravity" = "true" ]; then harness="antigravity"; else harness="claude"; fi
  fi

  case "$harness" in
    antigravity)
      if [ "$decision" = "allow" ]; then
        printf '{"decision":"allow"}\n'
      else
        jq -cn --arg r "$reason" '{decision:"deny",reason:$r}'
      fi
      ;;
    cursor)
      if [ "$decision" = "allow" ]; then
        printf '{"permission":"allow"}\n'
      else
        jq -cn --arg r "$reason" '{permission:"deny",user_message:$r,agent_message:$r}'
      fi
      ;;
    *)
      # Claude Code / Codex (and Cursor via its Claude-compatible import).
      if [ "$decision" = "deny" ]; then
        jq -cn --arg r "$reason" \
          '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
      fi
      ;;
  esac
}
