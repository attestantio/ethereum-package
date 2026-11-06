#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 ENCLAVE" >&2
  exit 2
fi

enclave=$1
kurtosis service inspect "$enclave" vc-2-geth-lighthouse-vouch
kurtosis enclave inspect "$enclave" | grep -A 2 -F 'vc-2-geth-lighthouse-vouch' | grep -q 'RUNNING'
config=$(kurtosis service exec "$enclave" vc-2-geth-lighthouse-vouch 'cat /config/vouch.yml')
# Vouch has one beacon node, so the package's majority threshold drops to 1.
grep -q 'threshold: 1' <<<"$config"
# vouch_strategies changes the proposal timeout and keeps the package's style.
proposal=$(grep -A 2 '^  beaconblockproposal:' <<<"$config")
grep -qF "style: 'best'" <<<"$proposal"
grep -qF "timeout: '1800ms'" <<<"$proposal"
# Vouch runs the strategy the override selected, not only renders it. The log store can trail
# the launch by a few seconds, so read the logs until the line shows up.
for _ in $(seq 30); do
  logs=$(kurtosis service logs -a "$enclave" vc-2-geth-lighthouse-vouch || true)
  if grep -qF 'Starting first beacon block root strategy' <<<"$logs"; then
    break
  fi
  sleep 2
done
grep -qF 'Starting first beacon block root strategy' <<<"$logs"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
kurtosis files download "$enclave" dkg-validators-file "$workdir"
dkg_pubkey=$(awk -F: '/^0x/ { print $1; exit }' "$workdir/validators.txt")
beacon_address=$(kurtosis port print "$enclave" cl-1-lighthouse-geth http --format ip,number | tr ' ' ':')
beacon_url="http://$beacon_address"

curl --fail-with-body --silent --show-error \
  "$beacon_url/eth/v1/beacon/states/genesis/validators/$dkg_pubkey" \
  | jq -e --arg pubkey "$dkg_pubkey" '(.data.validator.pubkey | ascii_downcase) == $pubkey' >/dev/null
curl --fail-with-body --silent --show-error \
  "$beacon_url/eth/v1/beacon/states/genesis/validators" \
  | jq -e '.data | length == 2' >/dev/null

# Vouch holds half the stake, so finality proves it attests through Dirk.
for _ in $(seq 120); do
  # A failed request counts as not yet finalized.
  finalized=$(curl --fail-with-body --silent --show-error \
    "$beacon_url/eth/v1/beacon/states/head/finality_checkpoints" | jq -r '.data.finalized.epoch' || echo 0)
  if (( finalized >= 1 )); then
    exit 0
  fi
  sleep 10
done
echo "chain did not finalize within 20 minutes" >&2
exit 1
