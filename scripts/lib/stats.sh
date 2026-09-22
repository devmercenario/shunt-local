#!/bin/bash
# `shunt-local stats`: summarize the audit log.
# Sourced by scripts/shunt-local.

shunt_stats() {
  local json_mode=false
  if [ "${1:-}" = "--json" ]; then json_mode=true; fi

  local log="${SHUNT_AUDIT_LOG:-$HOME/.config/shunt-local/audit.log}"

  if [ ! -s "$log" ]; then
    if [ "$json_mode" = true ]; then
      printf '{"total":0,"by_tool":{},"by_status":{},"by_sandbox":{},"rolled_back":0}\n'
    else
      echo "No audit records yet ($log)."
    fi
    return 0
  fi

  # Tolerate malformed lines: parse each with fromjson? and drop failures.
  local summary
  summary=$(jq -R -s '
    split("\n")
    | map(fromjson? // empty)
    | map(select(type == "object"))
    | {
        total: length,
        by_tool: (group_by(.tool // "?") | map({key: (.[0].tool // "?"), value: length}) | from_entries),
        by_status: (group_by(.status // "?") | map({key: (.[0].status // "?"), value: length}) | from_entries),
        by_sandbox: (map(select(.sandbox != null) | .sandbox) | group_by(.) | map({key: .[0], value: length}) | from_entries),
        rolled_back: (map(select(.rolled_back == "true")) | length)
      }
  ' "$log" 2>/dev/null)

  if [ -z "$summary" ]; then
    echo "Error: could not parse audit log ($log)." >&2
    return 1
  fi

  if [ "$json_mode" = true ]; then
    printf '%s\n' "$summary"
    return 0
  fi

  local total
  total=$(printf '%s' "$summary" | jq -r '.total')
  echo "shunt-local stats ($log)"
  printf "  total records: %s\n" "$total"
  echo "  by tool:"
  printf '%s' "$summary" | jq -r '.by_tool | to_entries[] | "    \(.key): \(.value)"'
  echo "  by status:"
  printf '%s' "$summary" | jq -r '.by_status | to_entries[] | "    \(.key): \(.value)"'
  if [ "$(printf '%s' "$summary" | jq -r '.by_sandbox | length')" != "0" ]; then
    echo "  by sandbox:"
    printf '%s' "$summary" | jq -r '.by_sandbox | to_entries[] | "    \(.key): \(.value)"'
  fi
  printf "  rollbacks: %s\n" "$(printf '%s' "$summary" | jq -r '.rolled_back')"
  return 0
}
