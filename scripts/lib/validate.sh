#!/bin/bash
# Command validation (strict token allowlist + program denylist) and shell-free
# execution. Sourced by local-llm.sh (do not execute directly).

# Security — validate a verification/rollback command before execution.
shunt_validate_exec_command() {
  local cmd="$1" label="$2"
  [ -z "$cmd" ] && return 0

  # Explicitly reject control characters (newline, CR, tab) that can be used to
  # chain commands. Harmless without a shell, but rejected for clarity.
  case "$cmd" in
    *$'\n'*|*$'\r'*|*$'\t'*)
      echo "🔒 BLOCKED: $label contains a control character (newline/CR/tab)." >&2
      return 1
      ;;
  esac

  # Tokenize literally (no shell, no globbing, no expansion). `read -r -a` only
  # performs word splitting, so $VAR, ${...}, $(...), backticks, redirections,
  # pipes, ;, && and newlines are inert once we exec the argv directly below.
  local -a argv=()
  read -r -a argv <<< "$cmd" || true
  if [ ${#argv[@]} -eq 0 ]; then
    return 0
  fi

  # Strict per-token allowlist. Any shell metacharacter, quote, expansion,
  # newline or glob character makes the token invalid; such commands require
  # the explicit --allow-unsafe + SHUNT_ALLOW_UNSAFE=true escape hatch.
  local tok
  for tok in "${argv[@]}"; do
    # Backslash is allowed: commands are exec'd as argv without a shell, so it
    # cannot escape anything (Windows paths need it).
    if ! [[ "$tok" =~ ^[A-Za-z0-9_./:=@+\\-]+$ ]]; then
      echo "🔒 BLOCKED: $label contains an unsafe token: '$tok'" >&2
      echo "   Only simple commands are allowed by default." >&2
      echo "   Bypass with --allow-unsafe + SHUNT_ALLOW_UNSAFE=true if truly needed." >&2
      return 1
    fi
  done

  # Program denylist: network clients (exfiltration), file readers/writers whose
  # output could leak secrets into test_output, and persistence/interpreter tools.
  local prog="${argv[0]##*/}"
  prog="${prog##*\\}"
  prog=$(printf '%s' "$prog" | tr '[:upper:]' '[:lower:]')
  case "$prog" in
    curl|wget|nc|ncat|netcat|socat|telnet|ssh|scp|sftp|rsync|ftp|lftp|smbclient|\
    sh|bash|zsh|dash|ksh|fish|env|eval|exec|source|\
    systemctl|service|reboot|shutdown|poweroff|halt|init|crontab|at|batch|\
    sudo|doas|su|pkexec|\
    rm|rmdir|unlink|dd|mkfs|mke2fs|shred|truncate|chmod|chown|chgrp|\
    cp|mv|ln|install|mkfifo|mknod|mount|umount|kill|pkill|killall|\
    cat|tac|head|tail|less|more|bat|nl|pr|sed|awk|gawk|mawk|grep|egrep|fgrep|rg|ag|\
    cut|sort|uniq|tr|strings|xxd|od|hexdump|base64|openssl|gpg|age|\
    env|printenv|set|ls|find|locate|tar|zip|unzip|7z|git|hg|svn|\
    docker|podman|kubectl|helm|terraform|\
    cryptominer|xmrig)
      echo "🔒 BLOCKED: '$prog' is not allowed as a verification/rollback command." >&2
      echo "   Use a real test runner (npm/pytest/go/cargo/make/...) or --allow-unsafe." >&2
      return 1
      ;;
  esac

  # Inline interpreter evaluation (defense in depth; the allowlist above already
  # rejects the punctuation these payloads need). Only flags that clearly mean
  # "run this string as code" are blocked, per interpreter.
  local inline_eval=0
  local -a rest=("${argv[@]:1}")
  for tok in ${rest[@]+"${rest[@]}"}; do
    case "$prog" in
      python|python2|python3|python3.*)
        case "$tok" in -c|--command) inline_eval=1 ;; esac ;;
      node|nodejs|deno|bun)
        case "$tok" in -e|--eval|-p|--print) inline_eval=1 ;; esac ;;
      ruby)
        case "$tok" in -e) inline_eval=1 ;; esac ;;
      perl)
        case "$tok" in -e|-E) inline_eval=1 ;; esac ;;
      php)
        case "$tok" in -r) inline_eval=1 ;; esac ;;
      lua)
        case "$tok" in -e) inline_eval=1 ;; esac ;;
    esac
    if [ "${inline_eval:-0}" = "1" ]; then
      echo "🔒 BLOCKED: $label uses inline interpreter evaluation ('$tok')." >&2
      echo "   Pass a script file instead, or use --allow-unsafe." >&2
      return 1
    fi
  done

  return 0
}

# Execute a command that has already passed shunt_validate_exec_command. Never
# invokes a shell: the command is tokenized literally and executed as argv, so
# metacharacters, expansions and redirections cannot take effect.
shunt_run_simple_command() {
  local cmd="$1"
  local -a argv=()
  read -r -a argv <<< "$cmd" || true
  [ ${#argv[@]} -eq 0 ] && return 0
  "${argv[@]}"
}
