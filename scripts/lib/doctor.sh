#!/bin/bash
# `shunt-local doctor`: diagnose the local installation.
# Sourced by scripts/shunt-local (the shared library is already loaded).

shunt_doctor() {
  local json_mode=false
  if [ "${1:-}" = "--json" ]; then json_mode=true; fi

  local n_pass=0 n_warn=0 n_fail=0
  local -a records=()

  _rec() { # status name message
    local status="$1" name="$2" message="$3"
    case "$status" in
      pass) n_pass=$((n_pass + 1)) ;;
      warn) n_warn=$((n_warn + 1)) ;;
      fail) n_fail=$((n_fail + 1)) ;;
    esac
    records+=("$status|$name|$message")
    if [ "$json_mode" = false ]; then
      local color="\033[32m"
      if [ "$status" = "warn" ]; then color="\033[33m"; fi
      if [ "$status" = "fail" ]; then color="\033[31m"; fi
      printf "  ${color}%-4s\033[0m %-24s %s\n" "$status" "$name" "$message"
    fi
  }

  # 1. Dependencies
  local missing="" cmd
  for cmd in jq curl python3 git; do
    command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
  done
  if [ -n "$missing" ]; then
    _rec fail deps "missing:$missing"
  else
    _rec pass deps "jq, curl, python3, git present"
  fi

  # 2. Configuration
  local cfg_file=""
  if [ -n "${SHUNT_CONFIG_PATH:-}" ] && [ -f "$SHUNT_CONFIG_PATH" ]; then
    cfg_file="$SHUNT_CONFIG_PATH"
  elif [ -f "$HOME/.config/shunt-local/config.json" ]; then
    cfg_file="$HOME/.config/shunt-local/config.json"
  fi
  if [ -z "$cfg_file" ]; then
    _rec warn config "no config file found (defaults in use)"
  elif ! jq -e . "$cfg_file" >/dev/null 2>&1; then
    _rec fail config "invalid JSON: $cfg_file"
  else
    _rec pass config "valid config: $cfg_file"
    local mode
    mode=$(stat -c '%a' "$cfg_file" 2>/dev/null || stat -f '%Lp' "$cfg_file" 2>/dev/null || echo "")
    if [ -n "$mode" ] && [ "$mode" != "600" ] && [ "$mode" != "400" ]; then
      _rec warn config-perms "config is $mode (expected 600)"
    else
      _rec pass config-perms "config permissions: ${mode:-unknown}"
    fi
  fi

  # 3. Endpoint validation + reachability
  if shunt_validate_endpoint "$SHUNT_ENDPOINT" >/dev/null 2>&1; then
    _rec pass endpoint "$SHUNT_ENDPOINT"
    if shunt_is_online; then
      _rec pass endpoint-online "local LLM server reachable"
    else
      _rec warn endpoint-online "server offline (hooks fail-open to cloud)"
    fi
  else
    _rec fail endpoint "endpoint rejected: $SHUNT_ENDPOINT"
  fi

  # 4. Sandbox
  local backend
  backend=$(shunt_sandbox_backend 2>/dev/null || echo none)
  if [ "$backend" = "none" ]; then
    if [ "${SHUNT_SANDBOX_STRICT:-false}" = "true" ]; then
      _rec fail sandbox "no sandbox backend and SHUNT_SANDBOX_STRICT=true"
    else
      _rec warn sandbox "no sandbox backend (test commands run unsandboxed)"
    fi
  else
    _rec pass sandbox "backend: $backend"
  fi

  # 5. Secret redaction
  if [ -f "${SHUNT_LIB_DIR:-}/redact.py" ]; then
    _rec pass redaction "redact.py present"
  else
    _rec fail redaction "redact.py missing (SHUNT_LIB_DIR=${SHUNT_LIB_DIR:-unset})"
  fi

  # 6. Audit log writable
  local audit="${SHUNT_AUDIT_LOG:-$HOME/.config/shunt-local/audit.log}"
  local audit_dir
  audit_dir=$(dirname "$audit")
  if mkdir -p "$audit_dir" 2>/dev/null && : >>"$audit" 2>/dev/null; then
    _rec pass audit-log "writable: $audit"
  else
    _rec warn audit-log "not writable: $audit"
  fi

  # 7. Harness registration
  if command -v agy >/dev/null 2>&1; then
    if [ -f "$HOME/.gemini/config/hooks.json" ] && grep -q '"shunt-local"' "$HOME/.gemini/config/hooks.json" 2>/dev/null; then
      _rec pass harness-antigravity "hooks registered"
    else
      _rec warn harness-antigravity "agy present but hooks not registered"
    fi
  fi
  if [ -f "$HOME/.config/opencode/plugins/shunt-local.ts" ]; then
    _rec pass harness-opencode "plugin installed"
  elif command -v opencode >/dev/null 2>&1; then
    _rec warn harness-opencode "opencode present but plugin missing"
  fi
  if [ -f "$HOME/.cursor/hooks.json" ] && grep -q 'shunt_guard.py' "$HOME/.cursor/hooks.json" 2>/dev/null; then
    _rec pass harness-cursor "hooks registered"
  elif [ -d "$HOME/.cursor" ]; then
    _rec warn harness-cursor "cursor present but hooks missing"
  fi
  if command -v claude >/dev/null 2>&1; then
    if [ -f "$HOME/.claude/settings.json" ] && grep -q 'shunt-local\|shunt_guard' "$HOME/.claude/settings.json" 2>/dev/null; then
      _rec pass harness-claude "configured"
    else
      _rec warn harness-claude "claude present; verify the plugin is installed"
    fi
  fi

  # 8. Trust record
  if [ -f "$HOME/.config/shunt-local/install_root" ]; then
    _rec pass trust "install root recorded"
  else
    _rec warn trust "no install_root recorded (re-run install.sh)"
  fi

  local status="ok"
  if [ "$n_warn" -gt 0 ]; then status="warn"; fi
  if [ "$n_fail" -gt 0 ]; then status="fail"; fi

  if [ "$json_mode" = true ]; then
    local checks="[]" rec st name msg
    for rec in "${records[@]}"; do
      st="${rec%%|*}"; rec="${rec#*|}"
      name="${rec%%|*}"; msg="${rec#*|}"
      checks=$(jq -c --argjson c "$checks" --arg s "$st" --arg n "$name" --arg m "$msg" \
        '$c + [{status:$s, check:$n, message:$m}]' <<<"$checks")
    done
    jq -cn --arg status "$status" --argjson checks "$checks" \
      --argjson pass "$n_pass" --argjson warn "$n_warn" --argjson fail "$n_fail" \
      '{status:$status, pass:$pass, warn:$warn, fail:$fail, checks:$checks}'
  else
    echo ""
    printf "  Result: %s (pass=%d warn=%d fail=%d)\n" "$status" "$n_pass" "$n_warn" "$n_fail"
  fi

  [ "$n_fail" -eq 0 ]
}
