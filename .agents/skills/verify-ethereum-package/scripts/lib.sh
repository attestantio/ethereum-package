#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts.

# EL and CL service names (kind el or cl) in `kurtosis enclave inspect` output.
services_of() { grep -oE "\\b$1-[0-9]+-[a-z0-9-]+" <<<"$2" | sort -u; }

# URL of a service port, or empty. Use this, not the inspect table: the metrics
# column also holds http:// URLs and parses to the wrong port.
port_url() { kurtosis port print "$1" "$2" "$3" 2>/dev/null; }

# Result of a parameterless JSON-RPC call (el_rpc <url> <method>), or empty.
el_rpc() {
  curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":[]}" "$1" | jq -r '.result // empty'
}
