#!/usr/bin/env bash
# Read-only check: is this enclave worth driving?
# Usage: doctor.sh <enclave> [epoch]
# With an epoch, it also prints when that epoch starts, e.g. the recipe's health epoch.
# It also prints when the first fork the network schedules after genesis starts: INFO while it is ahead,
# WARN once it has started, because a launch that returned after it did not cross it live.
# Exit 0 when every check passes, 1 otherwise, 2 when the check could not run (bad arguments, enclave not found).
set -uo pipefail
if [[ $# -lt 1 || $# -gt 2 || ! "${2:-0}" =~ ^[0-9]+$ ]]; then
  echo "usage: $0 <enclave> [epoch]" >&2
  exit 2
fi
enclave="$1"
target_epoch="${2:-}"
source "$(dirname "$0")/lib.sh"
rc=0
ok()  { printf 'PASS %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; rc=1; }

inspect="$(inspect_enclave "$enclave" --full-uuids)" || exit 2
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
    timing="$genesis $sps $(curl -fsS -m 5 "$url/eth/v1/config/spec" | jq -r .data.SLOTS_PER_EPOCH)"
    # "<epoch> <NAME>" of the earliest fork that is neither at genesis nor at the far-future epoch, or empty.
    fork="$(curl -fsS -m 5 "$url/eth/v1/config/spec" | jq -r '[.data | to_entries[] | select((.key | endswith("_FORK_EPOCH")) and .value != "0" and .value != "18446744073709551615") | {name: (.key | sub("_FORK_EPOCH$"; "")), epoch: (.value | tonumber)}] | min_by(.epoch) // empty | "\(.epoch) \(.name)"')"
    now=$(date +%s)
    if (( now < genesis )); then ok "$cl waiting for genesis in $((genesis - now))s"; continue; fi
    expected=$(( (now - genesis) / sps ))
    (( expected - head <= 2 )) && ok "$cl head $head, wall-clock slot $expected" || bad "$cl head $head lags wall-clock slot $expected"
  else
    bad "$cl beacon API not reachable at ${url:-<no http port>}"
  fi
done

# Timing, from the last beacon node that answered. Before genesis the epoch is negative.
if [[ -n "${timing:-}" ]]; then
  read -r genesis sps spe <<<"$timing"
  epoch_s=$(( sps * spe ))
  at() { date -u -r "$1" +%FT%TZ 2>/dev/null || date -u -d "@$1" +%FT%TZ; }
  printf 'INFO genesis %s, %ss slots, %ss epochs, wall-clock epoch %s\n' "$(at "$genesis")" "$sps" "$epoch_s" $(( ($(date +%s) - genesis) / epoch_s ))
  [[ -n "$target_epoch" ]] && printf 'INFO epoch %s starts at %s\n' "$target_epoch" "$(at $(( genesis + target_epoch * epoch_s )))"
  if [[ -n "${fork:-}" ]]; then
    read -r fork_epoch fork_name <<<"$fork"
    fork_at=$(( genesis + fork_epoch * epoch_s ))
    if (( $(date +%s) < fork_at )); then
      printf 'INFO fork %s at epoch %s starts at %s\n' "$fork_name" "$fork_epoch" "$(at "$fork_at")"
    else
      printf 'WARN fork %s at epoch %s started at %s: a launch that returned after it did not cross it live\n' "$fork_name" "$fork_epoch" "$(at "$fork_at")"
    fi
  fi
fi
exit "$rc"
