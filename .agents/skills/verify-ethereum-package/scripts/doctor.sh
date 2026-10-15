#!/usr/bin/env bash
# Read-only check: is this enclave worth driving?
# Usage: doctor.sh <enclave>
# Exit 0 when every check passes, 1 otherwise, 2 when the enclave is not found.
set -uo pipefail
if [[ $# -ne 1 ]]; then
  echo "usage: $0 <enclave>" >&2
  exit 2
fi
enclave="$1"
source "$(dirname "$0")/lib.sh"
rc=0
ok()  { printf 'PASS %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; rc=1; }

inspect="$(kurtosis enclave inspect --full-uuids "$enclave" 2>/dev/null)" || { bad "enclave $enclave not found"; exit 2; }
status="$(awk '/^Status:/ {print $2; exit}' <<<"$inspect")"
[[ "$status" == RUNNING ]] && ok "enclave $enclave $(awk '/^UUID:/ {print $2; exit}' <<<"$inspect") is RUNNING" || bad "enclave status is $status"

# Long-running services are el-, cl-, vc-, dirk- and tempo; one-shot setup tasks are expected to exit.
services=0
while read -r name state; do
  services=$((services + 1))
  [[ "$state" == running ]] && ok "$name running" || bad "$name is $state"
done < <(docker ps -a --filter "label=kurtosis_enclave_name=$enclave" \
  --format '{{.Label "kurtosis_service_name"}} {{.State}}' | grep -E '^((el|cl|vc|dirk)-|tempo )' | sort)
(( services > 0 )) || bad "no el, cl, vc, dirk or tempo containers found for $enclave"

# Every beacon node must be at most 2 slots behind the wall clock.
cls=$(services_of cl "$inspect")
[[ -n "$cls" ]] || bad "no beacon nodes found in $enclave"
for cl in $cls; do
  url="$(port_url "$enclave" "$cl" http)"
  if genesis="$(curl -fsS -m 5 "$url/eth/v1/beacon/genesis" | jq -r .data.genesis_time)" &&
     sps="$(curl -fsS -m 5 "$url/eth/v1/config/spec" | jq -r .data.SECONDS_PER_SLOT)" &&
     head="$(curl -fsS -m 5 "$url/eth/v1/beacon/headers/head" | jq -r .data.header.message.slot)"; then
    now=$(date +%s)
    if (( now < genesis )); then ok "$cl waiting for genesis in $((genesis - now))s"; continue; fi
    expected=$(( (now - genesis) / sps ))
    (( expected - head <= 2 )) && ok "$cl head $head, wall-clock slot $expected" || bad "$cl head $head lags wall-clock slot $expected"
  else
    bad "$cl beacon API not reachable at ${url:-<no http port>}"
  fi
done
exit "$rc"
