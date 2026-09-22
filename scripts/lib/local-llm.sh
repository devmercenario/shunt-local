#!/bin/bash
# Shared Local LLM plumbing for shunt-local delegation scripts.
#
# This file is a thin loader: the implementation lives in sibling modules so each
# concern is reviewable and testable in isolation:
#   common.sh   lib dir, temp files, path helpers, sensitive names, redaction
#   config.sh   config load, endpoint validation, enable/disable
#   validate.sh command allowlist/denylist + shell-free execution
#   sandbox.sh  bwrap/firejail/docker execution
#   audit.sh    audit log
#   http.sh     request/response handling
#   hooks.sh    PreToolUse decision emitter
#
# Connects to any OpenAI-compatible completions endpoint (llama.cpp / llama-server,
# Ollama, vLLM).

_shunt_lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _shunt_module in common config validate sandbox audit http hooks; do
  # shellcheck source=/dev/null
  . "$_shunt_lib_dir/$_shunt_module.sh"
done
unset _shunt_lib_dir _shunt_module

# Warn at load time if a project config exists but is not enabled (potential
# poisoning). Project configs are only honored with SHUNT_ALLOW_PROJECT_CONFIG=true.
if [ -f "./shunt.config.json" ] && [ "${SHUNT_ALLOW_PROJECT_CONFIG:-}" != "true" ]; then
  echo "⚠️  shunt-local: ./shunt.config.json detected but IGNORED (requires SHUNT_ALLOW_PROJECT_CONFIG=true)." >&2
fi

shunt_load_config
