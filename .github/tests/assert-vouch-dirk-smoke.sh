#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 ENCLAVE" >&2
  exit 2
fi

enclave=$1
kurtosis service inspect "$enclave" vc-2-geth-lighthouse-vouch
kurtosis enclave inspect "$enclave" | grep -A 2 -F 'vc-2-geth-lighthouse-vouch' | grep -q 'RUNNING'

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
