#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 ]] || { echo "usage: $0 ENCLAVE" >&2; exit 2; }
enclave=$1
vouch_ref=attestant/vouch:1.13.1@sha256:b0c20471db638922b0670b0c375033b25fc408dc7d38131b8fd4a4f35cd60d3b
dirk_ref=attestant/dirk:1.2.1@sha256:be451a000be3d36b11ca63668b77ef063386a349775bcc41a5e2be5cfef09fc0
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
    vc-*) echo "$image" | grep -F "$vouch_ref" ;;
    dirk-*) echo "$image" | grep -F "$dirk_ref" ;;
  esac
done
# Every Vouch and Dirk reference in the fixture is pinned by digest.
! grep -Eq 'attestant/(vouch|dirk):[^@[:space:]]+([[:space:]]|$)' .github/tests/vouch-dirk-certmanager.yaml
