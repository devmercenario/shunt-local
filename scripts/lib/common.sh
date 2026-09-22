#!/bin/bash
# Common utilities for shunt-local shell scripts: library location, temp files,
# path helpers, sensitive-name detection and secret redaction.
# Sourced by local-llm.sh (do not execute directly).

# Directory this library lives in (for helper scripts such as redact.py).
SHUNT_LIB_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
export SHUNT_LIB_DIR

# Temporary file management with automatic cleanup on main process exit
SHUNT_TMPFILES=()
SHUNT_PID="$$"

shunt_cleanup() {
  if [ "$$" -eq "$SHUNT_PID" ]; then
    rm -f ${SHUNT_TMPFILES[@]+"${SHUNT_TMPFILES[@]}"} 2>/dev/null || true
  fi
}
trap shunt_cleanup EXIT INT TERM

shunt_tmpfile() {
  local f
  local old_umask
  old_umask=$(umask)
  umask 077
  f=$(mktemp) || { umask "$old_umask"; return 1; }
  umask "$old_umask"
  SHUNT_TMPFILES+=("$f")
  printf -v "$1" '%s' "$f"
}

shunt_preflight() {
  local missing=""
  command -v jq >/dev/null 2>&1 || missing="$missing jq"
  command -v curl >/dev/null 2>&1 || missing="$missing curl"

  if [ -n "$missing" ]; then
    echo "Error: missing required command(s):$missing" >&2
    echo "Please install them via your package manager." >&2
    return 1
  fi
  return 0
}

# Trim surrounding whitespace without interpreting backslashes (unlike xargs,
# which strips them and corrupts Windows paths).
shunt_trim() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Resolve a path to its physical location (portable; python3 is a dependency).
# On Windows/MSYS the path is translated with cygpath so Python and bash agree.
shunt_to_native() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w -- "$p" 2>/dev/null | tr -d '\r' || printf '%s' "$p"
  else
    printf '%s' "$p"
  fi
}

shunt_to_posix() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u -- "$p" 2>/dev/null | tr -d '\r' || printf '%s' "$p"
  else
    printf '%s' "$p"
  fi
}

shunt_realpath() {
  local p
  p=$(shunt_to_native "$1")
  p=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p" 2>/dev/null | tr -d '\r' || printf '%s' "$p")
  shunt_to_posix "$p"
}

# Membership test for a newline-delimited list (exact match, no regex).
shunt_list_contains() {
  local needle="$1" list="${2:-}" line
  while IFS= read -r line; do
    [ "$line" = "$needle" ] && return 0
  done <<< "$list"
  return 1
}

# Is a single path component a protected name? (canonical list + .env.* family)
shunt_is_sensitive_name() {
  local name="$1" line
  case "$name" in .env.*) return 0 ;; esac
  local file="${SHUNT_LIB_DIR:-}/sensitive-names.txt"
  [ -f "$file" ] || return 1
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    [ "$line" = "$name" ] && return 0
  done < "$file"
  return 1
}

# Does any component of a path match a protected name?
shunt_path_sensitive() {
  local p="${1//\\//}" part
  local IFS='/'
  for part in $p; do
    [ -n "$part" ] || continue
    shunt_is_sensitive_name "$part" && return 0
  done
  return 1
}

# Reads are confined to the working directory unless explicitly opted out.
shunt_read_allowed() {
  local p="$1" real cwd
  cwd=$(pwd -P)
  real=$(shunt_realpath "$p")
  case "$real" in
    "$cwd"|"$cwd"/*) return 0 ;;
  esac
  [ "${SHUNT_ALLOW_READS_OUTSIDE_CWD:-}" = "true" ] && return 0
  [ "${SHUNT_ALLOW_WRITES_OUTSIDE_CWD:-}" = "true" ] && return 0
  return 1
}

# Redact secrets from $1 into $2. Returns non-zero when SHUNT_BLOCK_ON_SECRETS
# is enabled and a secret was found.
shunt_redact_file() {
  local in="$1" out="$2"
  if [ "${SHUNT_REDACT_SECRETS:-true}" != "true" ]; then
    cp -- "$in" "$out"
    return 0
  fi
  local err_file
  shunt_tmpfile err_file || return 1
  if ! python3 "$SHUNT_LIB_DIR/redact.py" < "$in" > "$out" 2> "$err_file"; then
    echo "Error: secret redaction failed." >&2
    return 1
  fi
  if [ -s "$err_file" ]; then
    local summary
    summary=$(tr -d '\n' < "$err_file")
    if [ "${SHUNT_BLOCK_ON_SECRETS:-false}" = "true" ]; then
      echo "🔒 BLOCKED: secrets detected in the payload; refusing to send to the endpoint." >&2
      echo "   Detected: $summary" >&2
      return 1
    fi
    echo "⚠️  shunt-local: redacted secrets before sending to the endpoint ($summary)." >&2
  fi
  return 0
}
