#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 ENCLAVE" >&2; exit 2; }
enclave=$1
service=vc-2-geth-lighthouse-vouch
kurtosis enclave inspect "$enclave" | grep -A 2 -F "$service" | grep -q RUNNING

config=$(kurtosis service exec "$enclave" "$service" 'cat /config/vouch.yml')
grep -q "style: 'static-delay'" <<<"$config"
grep -q "attester-delay: '250ms'" <<<"$config"
grep -q "proposer-delay: '500ms'" <<<"$config"
# The active instance manages exactly the account its cluster created.
grep -q "'DistributedWallet/0'" <<<"$config"
test "$(grep -c "'DistributedWallet/" <<<"$config")" -eq 1
# Static-delay starts inactive until arbitration promotes the instance.
logs=$(kurtosis service logs -a "$enclave" "$service")
grep -q 'attester_active":false' <<<"$logs"
