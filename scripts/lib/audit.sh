#!/bin/bash
# Audit log. Sourced by local-llm.sh (do not execute directly).

# Append a JSONL audit record to ~/.config/shunt-local/audit.log (0600).
# Usage: shunt_audit <tool> key=value [key=value ...]
shunt_audit() {
  local tool="$1"; shift
  local log="${SHUNT_AUDIT_LOG:-$HOME/.config/shunt-local/audit.log}"
  local dir
  dir=$(dirname "$log")
  mkdir -p "$dir" 2>/dev/null || return 0
  chmod 700 "$dir" 2>/dev/null || true
  local json='{}' kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    json=$(jq -cn --argjson o "$json" --arg k "$k" --arg v "$v" '$o + {($k): $v}' 2>/dev/null) || return 0
  done
  json=$(jq -cn --argjson o "$json" --arg tool "$tool" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '$o + {ts:$ts, tool:$tool}' 2>/dev/null) || return 0
  printf '%s\n' "$json" >> "$log" 2>/dev/null || return 0
  chmod 600 "$log" 2>/dev/null || true
  return 0
}
