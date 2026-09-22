#!/bin/bash
# Sandboxed command execution. Sourced by local-llm.sh (do not execute directly).
#
# SHUNT_SANDBOX          = auto | bwrap | firejail | docker | podman | none (default auto)
# SHUNT_SANDBOX_NETWORK  = true to keep network access (default false)
# SHUNT_SANDBOX_IMAGE    = image for the docker/podman backends
# SHUNT_SANDBOX_STRICT   = true to refuse to run when no sandbox is available
SHUNT_SANDBOX_BACKEND=""
SHUNT_SANDBOX_ARGV=()
SHUNT_SANDBOX_SELECTED=""

shunt_sandbox_probe() {
  case "$1" in
    bwrap)
      command -v bwrap >/dev/null 2>&1 || return 1
      bwrap --ro-bind / / --dev /dev --proc /proc -- /bin/true >/dev/null 2>&1
      ;;
    firejail) command -v firejail >/dev/null 2>&1 ;;
    docker|podman) command -v "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# Resolve the backend once per process and remember it in SHUNT_SANDBOX_SELECTED
# (avoids re-probing bwrap on every command).
shunt_sandbox_select() {
  [ -n "${SHUNT_SANDBOX_SELECTED:-}" ] && return 0
  local wanted="${SHUNT_SANDBOX:-auto}"
  case "$wanted" in
    none) SHUNT_SANDBOX_SELECTED="none"; return 0 ;;
    bwrap|firejail|docker|podman)
      if shunt_sandbox_probe "$wanted"; then SHUNT_SANDBOX_SELECTED="$wanted"; else SHUNT_SANDBOX_SELECTED="none"; fi
      return 0
      ;;
    auto)
      local b
      for b in bwrap firejail; do
        if shunt_sandbox_probe "$b"; then SHUNT_SANDBOX_SELECTED="$b"; return 0; fi
      done
      SHUNT_SANDBOX_SELECTED="none"; return 0
      ;;
    *)
      echo "Error: invalid SHUNT_SANDBOX='$wanted' (use auto|bwrap|firejail|docker|podman|none)." >&2
      return 1
      ;;
  esac
}

shunt_sandbox_backend() {
  shunt_sandbox_select || return 1
  printf '%s' "$SHUNT_SANDBOX_SELECTED"
}

# Wrap an argv into SHUNT_SANDBOX_ARGV. Usage: shunt_sandbox_wrap <argv...>
shunt_sandbox_wrap() {
  shunt_sandbox_select || return 1
  local backend="$SHUNT_SANDBOX_SELECTED"
  SHUNT_SANDBOX_BACKEND="$backend"
  local cwd
  cwd="${SHUNT_SANDBOX_CWD:-$(pwd -P)}"
  local -a base=("$@")
  local -a f=()
  case "$backend" in
    bwrap)
      f=(--die-with-parent --unshare-pid --unshare-ipc --unshare-uts)
      [ "${SHUNT_SANDBOX_NETWORK:-false}" != "true" ] && f+=(--unshare-net)
      f+=(--ro-bind / / --dev /dev --proc /proc)
      [ "${SHUNT_SANDBOX_ALLOW_TMP:-true}" = "true" ] && f+=(--tmpfs /tmp)
      f+=(--bind "$cwd" "$cwd" --chdir "$cwd")
      SHUNT_SANDBOX_ARGV=(bwrap "${f[@]}" -- "${base[@]}")
      ;;
    firejail)
      f=(--quiet --private-tmp --read-only=/ --read-write="$cwd" --chdir="$cwd")
      [ "${SHUNT_SANDBOX_NETWORK:-false}" != "true" ] && f+=(--net=none)
      SHUNT_SANDBOX_ARGV=(firejail "${f[@]}" -- "${base[@]}")
      ;;
    docker|podman)
      local img="${SHUNT_SANDBOX_IMAGE:-}"
      if [ -z "$img" ]; then
        echo "Error: SHUNT_SANDBOX_IMAGE is required for the $backend sandbox backend." >&2
        return 1
      fi
      f=(run --rm -v "$cwd:$cwd" -w "$cwd")
      [ "${SHUNT_SANDBOX_NETWORK:-false}" != "true" ] && f+=(--network none)
      SHUNT_SANDBOX_ARGV=("$backend" "${f[@]}" "$img" "${base[@]}")
      ;;
    *)
      SHUNT_SANDBOX_ARGV=("${base[@]}")
      ;;
  esac
  return 0
}

# Run a validated command. mode = argv (no shell) | shell (bash -c, unsafe path).
shunt_run_command() {
  local cmd="$1" mode="${2:-argv}"
  local -a base=()
  if [ "$mode" = "shell" ]; then
    base=(bash -c "$cmd")
  else
    read -r -a base <<< "$cmd" || true
    [ ${#base[@]} -eq 0 ] && return 0
  fi
  shunt_sandbox_wrap "${base[@]}" || return 1
  if [ "$SHUNT_SANDBOX_BACKEND" = "none" ]; then
    if [ "${SHUNT_SANDBOX_STRICT:-false}" = "true" ]; then
      echo "Error: no sandbox backend available and SHUNT_SANDBOX_STRICT=true." >&2
      return 1
    fi
    echo "⚠️  shunt-local: running without a sandbox; set SHUNT_SANDBOX_STRICT=true to refuse." >&2
  fi
  ${SHUNT_SANDBOX_ARGV[@]+"${SHUNT_SANDBOX_ARGV[@]}"}
}
