#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 ENCLAVE" >&2
  exit 2
fi

enclave=$1
for service in dirk-a-1 dirk-a-2 dirk-a-3 dirk-b-1 dirk-b-2 dirk-b-3 vc-2-geth-lighthouse-vouch vc-3-geth-lighthouse-vouch vc-4-geth-lighthouse-vouch; do
  kurtosis enclave inspect "$enclave" | grep -A 2 -F "$service" | grep -q RUNNING
done

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
for index in 2 3 4; do
  kurtosis service exec "$enclave" "vc-$index-geth-lighthouse-vouch" 'cat /config/vouch.yml' > "$workdir/vc-$index.yml"
done

grep -q 'DistributedWallet/0' "$workdir/vc-2.yml"
grep -q 'DistributedWallet/0' "$workdir/vc-3.yml"
grep -q 'DistributedWallet/1' "$workdir/vc-4.yml"
grep -q 'dirk-a-1:8881' "$workdir/vc-2.yml"
grep -q 'dirk-a-1:8881' "$workdir/vc-3.yml"
grep -q 'dirk-b-1:8881' "$workdir/vc-4.yml"
! grep -q 'dirk-b-' "$workdir/vc-2.yml"
! grep -q 'dirk-a-' "$workdir/vc-4.yml"

kurtosis files download "$enclave" dkg-validators-file "$workdir/dkg"
test "$(head -n 1 "$workdir/dkg/validators.txt")" = '# DKG validator pubkeys for genesis'
test "$(grep -c '^#' "$workdir/dkg/validators.txt")" = 1
test "$(grep -c '^0x' "$workdir/dkg/validators.txt")" = 2
test "$(grep '^0x' "$workdir/dkg/validators.txt" | cut -d: -f1 | sort -u | wc -l | tr -d ' ')" = 2

beacon_address=$(kurtosis port print "$enclave" cl-1-lighthouse-geth http --format ip,number | tr ' ' ':')
beacon_url="http://$beacon_address"
curl --fail-with-body --silent --show-error "$beacon_url/eth/v1/beacon/states/genesis/validators" | jq -e '.data | length == 3' >/dev/null
while IFS=: read -r pubkey _; do
  [[ $pubkey == 0x* ]] || continue
  curl --fail-with-body --silent --show-error "$beacon_url/eth/v1/beacon/states/genesis/validators/$pubkey" | jq -e --arg pubkey "$pubkey" '(.data.validator.pubkey | ascii_downcase) == $pubkey' >/dev/null
done < "$workdir/dkg/validators.txt"
