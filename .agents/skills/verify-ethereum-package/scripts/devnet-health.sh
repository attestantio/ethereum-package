#!/usr/bin/env bash
# Chain health across every client of one enclave: head progress, block-root
# agreement, finality and EL heights. Running containers or is_syncing=false
# are not health.
#
# Usage: devnet-health.sh <enclave>
# Exit 0 HEALTHY: every client is on one chain, close to the wall clock, and finalizing.
# Exit 1 UNHEALTHY: the majority chain is stalled, not justifying or not finalizing.
# Exit 2 DIVERGED: the majority chain is healthy but some client is off it, stalled or not finalizing.
set -uo pipefail
if [[ $# -ne 1 || -z "$1" ]]; then
  echo "usage: $0 <enclave>" >&2
  exit 2
fi
enclave="$1"
source "$(dirname "$0")/lib.sh"

FAIL=0
DIVERGED=""
note() { printf '%s\n' "$*"; }
ok()   { printf '  PASS %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; FAIL=1; }
warn() { printf '  WARN %s\n' "$*"; }
diverge() { printf '  DIVERGED %s: %s\n' "$1" "$2"; [[ " $DIVERGED " == *" $1 "* ]] || DIVERGED="$DIVERGED $1"; }
get() { curl -fsS -m 10 "$1$2" 2>/dev/null; }

inspect="$(kurtosis enclave inspect "$enclave" 2>/dev/null)" || { bad "enclave $enclave not found"; exit 1; }
mapfile -t CLS < <(services_of cl "$inspect")
mapfile -t ELS < <(services_of el "$inspect")
(( ${#CLS[@]} )) || { bad "no beacon nodes in $enclave"; exit 1; }
declare -A URL
for cl in "${CLS[@]}"; do URL[$cl]="$(port_url "$enclave" "$cl" http)"; done

# Spec and genesis from the first beacon node that answers.
for cl in "${CLS[@]}"; do
  spec="$(get "${URL[$cl]}" /eth/v1/config/spec)" && genesis="$(get "${URL[$cl]}" /eth/v1/beacon/genesis | jq -r .data.genesis_time)" && break
done
sps="$(jq -r .data.SECONDS_PER_SLOT <<<"${spec:-}" 2>/dev/null)"
spe="$(jq -r .data.SLOTS_PER_EPOCH <<<"${spec:-}" 2>/dev/null)"
[[ -n "${genesis:-}" && -n "$sps" && -n "$spe" ]] || { bad "no beacon node returned spec and genesis"; exit 1; }
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

# Block roots: the newest slot every answering client has passed, walking back
# over empty slots. The majority root is the chain; others are off it.
min_head=$wall
for cl in "${CLS[@]}"; do [[ -n "${HEAD[$cl]}" ]] && (( ${HEAD[$cl]} < min_head )) && min_head=${HEAD[$cl]}; done
declare -A ROOT CANON
slot=0
for back in $(seq 2 12); do
  try=$(( min_head - back )); (( try < 1 )) && break
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
  majority="$(for cl in "${CLS[@]}"; do [[ -n "${ROOT[$cl]}" ]] && echo "${ROOT[$cl]}"; done | sort | uniq -c | sort -rn | awk 'NR==1 {print $2}')"
  for cl in "${CLS[@]}"; do
    if [[ "${ROOT[$cl]}" == "$majority" ]]; then CANON[$cl]=1; ok "$cl has root ${majority:0:18} at slot $slot"
    else CANON[$cl]=0; diverge "$cl" "root at slot $slot is ${ROOT[$cl]:-missing}, majority has ${majority:0:18}"; fi
  done
else
  warn "chain too young or no slot near the heads has a block on a majority; root agreement not checked"
  for cl in "${CLS[@]}"; do CANON[$cl]=1; done
fi

note ""
note "per-client head and finality"
max_fin=0
for cl in "${CLS[@]}"; do (( ${CANON[$cl]} )) && [[ -n "${FIN[$cl]}" ]] && (( ${FIN[$cl]} > max_fin )) && max_fin=${FIN[$cl]}; done
head_epoch=$(( wall / spe ))
for cl in "${CLS[@]}"; do
  if [[ -z "${HEAD[$cl]}" ]]; then diverge "$cl" "beacon API does not answer"; continue; fi
  gap=$(( wall - ${HEAD[$cl]} )); (( gap < 0 )) && gap=0
  line="head ${HEAD[$cl]} ($gap behind wall clock), ${PEERS[$cl]:-?} peers, justified ${JUST[$cl]:-?}, finalized ${FIN[$cl]:-?}"
  if (( gap > 8 )); then diverge "$cl" "$line; stalled"
  elif [[ "${PEERS[$cl]:-0}" == 0 ]]; then diverge "$cl" "$line; no peers"
  elif (( head_epoch >= 5 )) && [[ "${FIN[$cl]:-0}" == 0 ]]; then diverge "$cl" "$line; nothing finalized by epoch $head_epoch"
  elif (( max_fin - ${FIN[$cl]:-0} > 2 )); then diverge "$cl" "$line; finality behind the others"
  else ok "$cl $line"; fi
done

# The majority chain itself.
note ""
note "majority chain"
canon_heads=(); for cl in "${CLS[@]}"; do (( ${CANON[$cl]} )) && [[ -n "${HEAD[$cl]}" ]] && canon_heads+=("${HEAD[$cl]}"); done
best_head=$(printf '%s\n' "${canon_heads[@]:-0}" | sort -n | tail -1)
if (( wall - best_head > 8 )); then bad "majority head $best_head is $(( wall - best_head )) slots behind the wall clock"; else ok "majority head $best_head"; fi
if (( head_epoch >= 5 )); then
  (( max_fin > 0 )) && ok "finalized epoch $max_fin at head epoch $head_epoch" || bad "nothing finalized by head epoch $head_epoch"
  (( head_epoch - max_fin > 6 )) && bad "finality $(( head_epoch - max_fin )) epochs behind head"
else
  warn "head epoch $head_epoch; first finality is expected around epoch 4"
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
  hx="$(curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
    "$(port_url "$enclave" "$el" rpc)" | jq -r .result)"
  if [[ -z "$hx" || "$hx" == null ]]; then diverge "$el" "no answer to eth_blockNumber"; continue; fi
  NUMS+=("$((hx))"); note "  $el = $((hx))"
done
if (( ${#NUMS[@]} > 1 )); then
  spread=$(( $(printf '%s\n' "${NUMS[@]}" | sort -n | tail -1) - $(printf '%s\n' "${NUMS[@]}" | sort -n | head -1) ))
  (( spread > 5 )) && warn "EL heights differ by $spread blocks" || ok "EL heights within $spread blocks"
fi

note ""
if (( FAIL )); then note "RESULT: UNHEALTHY"; exit 1; fi
if [[ -n "$DIVERGED" ]]; then note "RESULT: DIVERGED:$DIVERGED"; exit 2; fi
note "RESULT: HEALTHY"
