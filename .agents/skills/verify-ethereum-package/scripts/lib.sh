#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts.

# Service names of one kind (cl, el, vc, dirk) in `kurtosis enclave inspect` output.
services_of() { grep -oE "\\b$1-[0-9]+-[a-z0-9-]+" <<<"$2" | sort -u; }

# URL of a service port, or empty. Use this, not the inspect table: the metrics
# column also holds http:// URLs and parses to the wrong port.
port_url() { kurtosis port print "$1" "$2" "$3" 2>/dev/null; }
