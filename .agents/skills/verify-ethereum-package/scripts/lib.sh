#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts.

# mapfile and declare -A/-n need bash 4.3, and an empty array expands under set -u from 4.4. macOS /bin/bash is 3.2.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  echo "$0 needs bash 4.4 or newer, found $BASH_VERSION (macOS: brew install bash)" >&2
  exit 2
fi

# `kurtosis enclave inspect [flags] <enclave>` output. On failure it says which case it is: no such
# enclave, or the inspect itself failed (engine or Docker down), which does not prove the enclave
# is gone. Usage: inspect="$(inspect_enclave <enclave> [flags])" || exit 2
inspect_enclave() {
  local enclave="$1" out
  shift
  if ! out="$(kurtosis enclave inspect "$@" "$enclave" 2>&1)"; then
    if grep -q 'No enclave found' <<<"$out"; then
      echo "enclave $enclave not found" >&2
    else
      echo "kurtosis enclave inspect $enclave failed, which does not prove the enclave is absent: $(tail -n 1 <<<"$out")" >&2
    fi
    return 2
  fi
  printf '%s\n' "$out"
}

# EL and CL service names (kind el or cl) in `kurtosis enclave inspect` output.
services_of() { grep -oE "\\b$1-[0-9]+-[a-z0-9-]+" <<<"$2" | sort -u; }

# URL of a service port, or empty. Use this, not the inspect table: the metrics
# column also holds http:// URLs and parses to the wrong port.
port_url() { kurtosis port print "$1" "$2" "$3" 2>/dev/null; }

# JSON-RPC URL of an EL service. Erigon serves HTTP JSON-RPC on its ws-rpc port.
el_rpc_url() { port_url "$1" "$2" rpc || port_url "$1" "$2" ws-rpc; }

# Result of a parameterless JSON-RPC call (el_rpc <url> <method>), or empty.
el_rpc() {
  curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":[]}" "$1" | jq -r '.result // empty'
}
