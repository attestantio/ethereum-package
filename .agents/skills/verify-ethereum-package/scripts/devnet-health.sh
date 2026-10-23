#!/usr/bin/env bash
# Chain health across every client of one enclave: head progress, block-root
# agreement, finality and EL heights. Running containers or is_syncing=false
# are not health.
#
# Usage: devnet-health.sh <enclave> [health-epoch]
# Exit 0 HEALTHY: every client is on one chain, close to the wall clock, and finalizing.
# Exit 1 UNHEALTHY: no majority chain, or it is stalled, not justifying or not finalizing.
# Exit 2: the check could not run (bad arguments, no enclave, no beacon API).
# Exit 3 DIVERGED: the majority chain is healthy but some client is off it, stalled or not finalizing.
# Exit 4 INCOMPLETE: healthy so far, but the wall clock is before [health-epoch], so this is a smoke result.
set -uo pipefail
if [[ $# -lt 1 || $# -gt 2 || -z "$1" || ! "${2:-0}" =~ ^[0-9]+$ ]]; then
  echo "usage: $0 <enclave> [health-epoch]" >&2
  exit 2
fi
enclave="$1"
health_epoch="${2:-0}"
source "$(dirname "$0")/lib.sh"

FAIL=0
DIVERGED=""
note() { printf '%s\n' "$*"; }
ok()   { printf '  PASS %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; FAIL=1; }
warn() { printf '  WARN %s\n' "$*"; }
diverge() { printf '  DIVERGED %s: %s\n' "$1" "$2"; [[ " $DIVERGED " == *" $1 "* ]] || DIVERGED="$DIVERGED $1"; }
get() { curl -fsS -m 10 "$1$2" 2>/dev/null; }

inspect="$(kurtosis enclave inspect "$enclave" 2>/dev/null)" || { echo "enclave $enclave not found" >&2; exit 2; }
mapfile -t CLS < <(services_of cl "$inspect")
mapfile -t ELS < <(services_of el "$inspect")
(( ${#CLS[@]} )) || { echo "no beacon nodes in $enclave" >&2; exit 2; }
declare -A URL
for cl in "${CLS[@]}"; do URL[$cl]="$(port_url "$enclave" "$cl" http)"; done

# Spec and genesis from the first beacon node that answers.
for cl in "${CLS[@]}"; do
  spec="$(get "${URL[$cl]}" /eth/v1/config/spec)" && genesis="$(get "${URL[$cl]}" /eth/v1/beacon/genesis | jq -r .data.genesis_time)" && break
done
sps="$(jq -r .data.SECONDS_PER_SLOT <<<"${spec:-}" 2>/dev/null)"
spe="$(jq -r .data.SLOTS_PER_EPOCH <<<"${spec:-}" 2>/dev/null)"
[[ -n "${genesis:-}" && -n "$sps" && -n "$spe" ]] || { echo "no beacon node returned spec and genesis" >&2; exit 2; }
wall=$(( ($(date +%s) - genesis) / sps ))
note "enclave $enclave: ${#CLS[@]} beacon nodes, ${sps}s slots, $spe slots per epoch, wall-clock slot $wall"

# Per-client facts.
declare -A HEAD PEERS JUST FIN FINROOT
for cl in "${CLS[@]}"; do
  HEAD[$cl]="$(get "${URL[$cl]}" /eth/v1/beacon/headers/head | jq -r .data.header.message.slot)"
  PEERS[$cl]="$(get "${URL[$cl]}" /eth/v1/node/peer_count | jq -r .data.connected)"
  fc="$(get "${URL[$cl]}" /eth/v1/beacon/states/head/finality_checkpoints)"
  JUST[$cl]="$(jq -r .data.current_justified.epoch <<<"$fc" 2>/dev/null)"
  FIN[$cl]="$(jq -r .data.finalized.epoch <<<"$fc" 2>/dev/null)"
  FINROOT[$cl]="$(jq -r .data.finalized.root <<<"$fc" 2>/dev/null)"
  # A failed request reads as empty, never as "null".
  for v in HEAD PEERS JUST FIN FINROOT; do
    declare -n field=$v
    [[ "${field[$cl]}" == null ]] && field[$cl]=""
    unset -n field
  done
done

# Block roots near the newest head, walking back over empty slots. A client
# without a block there is behind or forked, and is judged as off the chain;
# the slot never moves back to wait for it. A strict majority root is the chain.
max_head=0
for cl in "${CLS[@]}"; do [[ -n "${HEAD[$cl]}" ]] && (( ${HEAD[$cl]} > max_head )) && max_head=${HEAD[$cl]}; done
declare -A ROOT CANON
slot=0
chain=1
for back in $(seq 2 12); do
  try=$(( max_head - back )); (( try < 1 )) && break
  have=0
  for cl in "${CLS[@]}"; do
    ROOT[$cl]="$(get "${URL[$cl]}" "/eth/v1/beacon/blocks/$try/root" | jq -r '.data.root // empty')"
    [[ -n "${ROOT[$cl]}" ]] && have=$((have + 1))
  done
  (( have * 2 > ${#CLS[@]} )) && { slot=$try; break; }
done
note ""
note "block roots"
if (( slot > 0 )); then
  read -r majority_count majority < <(for cl in "${CLS[@]}"; do [[ -n "${ROOT[$cl]}" ]] && echo "${ROOT[$cl]}"; done | sort | uniq -c | sort -rn | head -1)
  # Without a strict majority there is no chain to compare against: a split.
  if (( majority_count * 2 <= ${#CLS[@]} )); then
    bad "no root at slot $slot is shared by a majority of ${#CLS[@]} clients: the chain is split"
    majority=""; chain=0
  fi
  for cl in "${CLS[@]}"; do
    if [[ -z "$majority" ]]; then CANON[$cl]=0; note "  $cl root at slot $slot is ${ROOT[$cl]:-missing}"
    elif [[ "${ROOT[$cl]}" == "$majority" ]]; then CANON[$cl]=1; ok "$cl has root ${majority:0:18} at slot $slot"
    else CANON[$cl]=0; diverge "$cl" "root at slot $slot is ${ROOT[$cl]:-missing}, majority has ${majority:0:18}"; fi
  done
elif (( max_head < 3 )); then
  warn "chain too young (head $max_head); root agreement not checked"
  for cl in "${CLS[@]}"; do CANON[$cl]=1; done
else
  # A majority without blocks near the newest head is stalled or forked.
  bad "no slot from $(( max_head - 12 )) to $(( max_head - 2 )) has a block on a majority of ${#CLS[@]} clients"
  for cl in "${CLS[@]}"; do CANON[$cl]=0; done
  chain=0
fi

note ""
note "per-client head and finality"
max_fin=0
for cl in "${CLS[@]}"; do (( ${CANON[$cl]} )) && [[ -n "${FIN[$cl]}" ]] && (( ${FIN[$cl]} > max_fin )) && max_fin=${FIN[$cl]}; done
wall_epoch=$(( wall / spe ))
for cl in "${CLS[@]}"; do
  if [[ -z "${HEAD[$cl]}" ]]; then diverge "$cl" "beacon API does not answer"; continue; fi
  gap=$(( wall - ${HEAD[$cl]} )); (( gap < 0 )) && gap=0
  line="head ${HEAD[$cl]} ($gap behind wall clock), ${PEERS[$cl]:-?} peers, justified ${JUST[$cl]:-?}, finalized ${FIN[$cl]:-?}"
  if (( gap > 8 )); then diverge "$cl" "$line; stalled"
  elif [[ "${PEERS[$cl]:-0}" == 0 ]]; then diverge "$cl" "$line; no peers"
  elif (( wall_epoch >= 5 )) && [[ "${FIN[$cl]:-0}" == 0 ]]; then diverge "$cl" "$line; nothing finalized by epoch $wall_epoch"
  elif (( max_fin - ${FIN[$cl]:-0} > 2 )); then diverge "$cl" "$line; finality behind the others"
  else ok "$cl $line"; fi
done

# The majority chain itself.
note ""
note "majority chain"
best_head=0
if (( chain )); then
  canon_heads=(); for cl in "${CLS[@]}"; do (( ${CANON[$cl]} )) && [[ -n "${HEAD[$cl]}" ]] && canon_heads+=("${HEAD[$cl]}"); done
  best_head=$(printf '%s\n' "${canon_heads[@]:-0}" | sort -n | tail -1)
  if (( wall - best_head > 8 )); then bad "majority head $best_head is $(( wall - best_head )) slots behind the wall clock"; else ok "majority head $best_head"; fi
  max_just=0
  for cl in "${CLS[@]}"; do (( ${CANON[$cl]} )) && [[ -n "${JUST[$cl]}" ]] && (( ${JUST[$cl]} > max_just )) && max_just=${JUST[$cl]}; done
  if (( wall_epoch >= 4 )); then
    (( wall_epoch - max_just > 4 )) && bad "justification stuck at epoch $max_just at wall-clock epoch $wall_epoch" || ok "justified epoch $max_just at wall-clock epoch $wall_epoch"
  fi
  if (( wall_epoch >= 5 )); then
    (( max_fin > 0 )) && ok "finalized epoch $max_fin at wall-clock epoch $wall_epoch" || bad "nothing finalized by wall-clock epoch $wall_epoch"
    (( wall_epoch - max_fin > 6 )) && bad "finality $(( wall_epoch - max_fin )) epochs behind the wall clock"
  else
    warn "wall-clock epoch $wall_epoch; finality is judged from epoch 5"
  fi
else
  note "  skipped: there is no majority chain"
fi
# Two clients finalized at the same epoch with different roots is a split.
for a in "${CLS[@]}"; do for b in "${CLS[@]}"; do
  [[ "$a" < "$b" && -n "${FIN[$a]}" && "${FIN[$a]}" == "${FIN[$b]}" && "${FIN[$a]}" != 0 && "${FINROOT[$a]}" != "${FINROOT[$b]}" ]] &&
    bad "split finality: $a and $b finalized epoch ${FIN[$a]} with different roots"
done; done

# Missed slots on the majority chain, as information only.
ref=""; for cl in "${CLS[@]}"; do (( ${CANON[$cl]} )) && [[ "${HEAD[$cl]}" == "$best_head" ]] && { ref=$cl; break; }; done
if [[ -n "$ref" ]] && (( best_head > 0 )); then
  start=$(( best_head - 31 )); (( start < 1 )) && start=1
  missed=0
  for s in $(seq "$start" "$best_head"); do
    [[ "$(curl -s -m 8 -o /dev/null -w '%{http_code}' "${URL[$ref]}/eth/v1/beacon/blocks/$s/root")" == 200 ]] || missed=$((missed + 1))
  done
  note "  $missed of $(( best_head - start + 1 )) recent slots missed on $ref (information only)"
fi

note ""
note "execution layer heights"
declare -a NUMS
for el in "${ELS[@]}"; do
  hx="$(el_rpc "$(el_rpc_url "$enclave" "$el")" eth_blockNumber)"
  if [[ -z "$hx" ]]; then diverge "$el" "no answer to eth_blockNumber"; continue; fi
  NUMS+=("$((hx))"); note "  $el = $((hx))"
done
if (( ${#NUMS[@]} > 1 )); then
  spread=$(( $(printf '%s\n' "${NUMS[@]}" | sort -n | tail -1) - $(printf '%s\n' "${NUMS[@]}" | sort -n | head -1) ))
  (( spread > 5 )) && warn "EL heights differ by $spread blocks" || ok "EL heights within $spread blocks"
fi

note ""
if (( FAIL )); then note "RESULT: UNHEALTHY"; exit 1; fi
if [[ -n "$DIVERGED" ]]; then note "RESULT: DIVERGED:$DIVERGED"; exit 3; fi
if (( wall_epoch < health_epoch )); then note "RESULT: INCOMPLETE: wall-clock epoch $wall_epoch is before health epoch $health_epoch"; exit 4; fi
note "RESULT: HEALTHY"
