#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 ]] || { echo "usage: $0 ENCLAVE" >&2; exit 2; }
enclave=$1
vouch_digest=sha256:048a2384bf40dc6436b23a876e2f227dc70345b6bccbd7fa76a4d01182e4df5e
dirk_digest=sha256:0069f3212131492a027d63ddd599bbf50641a28c5cb0a5bafa23b0714aa733fc
services=(
  vc-1-geth-lighthouse-vouch
  vc-2-geth-lighthouse-vouch
  vc-3-geth-prysm-vouch
  dirk-a-1 dirk-a-2 dirk-a-3 dirk-a-4 dirk-a-5
  dirk-b-1 dirk-b-2 dirk-b-3 dirk-b-4 dirk-b-5
)
inspect=$(kurtosis enclave inspect "$enclave")
for service in "${services[@]}"; do
  echo "$inspect" | grep -A 2 -F "$service" | grep -q RUNNING
done
for service in "${services[@]}"; do
  image=$(kurtosis service inspect "$enclave" "$service" | grep -E 'Image|image' | head -1)
  case "$service" in
    vc-*) echo "$image" | grep -F "localhost:5001/attestant/vouch@$vouch_digest" ;;
    dirk-*) echo "$image" | grep -F "localhost:5001/attestant/dirk@$dirk_digest" ;;
  esac
done
! grep -Eq 'attestant/(vouch|dirk):[^@[:space:]]+' .github/tests/vouch-dirk-certmanager.yaml
