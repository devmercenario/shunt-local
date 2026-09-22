#!/bin/bash
# Update verification helpers for shunt-update.
# Kept in a small sourceable library so it can be unit-tested.

# Accept only the well-known public code hosts for a pull. Compared by exact
# hostname, so https://github.com.evil.example/... is correctly rejected.
shunt_remote_is_trusted() {
  local url="$1" host=""
  if [[ "$url" =~ ^[^@/]+@([^:/]+): ]]; then
    host="${BASH_REMATCH[1]}"
  elif [[ "$url" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]]; then
    host="${url#*://}"
    host="${host%%/*}"
    host="${host##*@}"
    host="${host%%:*}"
  fi
  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  case "$host" in
    github.com|gitlab.com|bitbucket.org) return 0 ;;
  esac
  return 1
}

# Verify a fetched ref before applying it.
#   $1 = repository directory
#   $2 = ref to verify (e.g. origin/main)
# Accepts either a signed commit (GPG/SSH) or a cosign-signed SHA256SUMS file.
shunt_verify_update() {
  local repo="$1" ref="$2"

  if command -v git >/dev/null 2>&1 && git -C "$repo" verify-commit "$ref" >/dev/null 2>&1; then
    echo "✔ update: $ref has a valid commit signature." >&2
    return 0
  fi

  local sums="$repo/SHA256SUMS" sig="$repo/SHA256SUMS.sig" cert="$repo/SHA256SUMS.pem"
  if command -v cosign >/dev/null 2>&1 && [ -f "$sums" ] && [ -f "$sig" ] && [ -f "$cert" ]; then
    if cosign verify-blob \
        --certificate "$cert" \
        --signature "$sig" \
        --certificate-identity-regexp "${SHUNT_UPDATE_SIGNER:-.*}" \
        --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
        "$sums" >/dev/null 2>&1; then
      echo "✔ update: SHA256SUMS verified with cosign." >&2
      return 0
    fi
  fi

  echo "🔒 update: could not verify $ref (no valid commit signature and no cosign attestation)." >&2
  return 1
}
