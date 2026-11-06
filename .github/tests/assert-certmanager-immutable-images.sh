#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 ]] || { echo "usage: $0 ENCLAVE" >&2; exit 2; }
enclave=$1
fixture=.github/tests/vouch-dirk-certmanager.yaml
# Every Vouch and Dirk reference in the fixture is pinned by digest.
if grep -Eq 'attestant/(vouch|dirk):[^@[:space:]]+([[:space:]]|$)' "$fixture"; then exit 1; fi
# The fixture pins one image per role; the deployed services must use exactly it.
vouch_ref=$(grep -oE 'attestant/vouch:[^[:space:]]+' "$fixture" | sort -u)
dirk_ref=$(grep -oE 'attestant/dirk:[^[:space:]]+' "$fixture" | sort -u)
[[ $(wc -l <<<"$vouch_ref") -eq 1 && $(wc -l <<<"$dirk_ref") -eq 1 ]]
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
