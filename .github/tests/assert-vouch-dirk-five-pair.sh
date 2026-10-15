#!/usr/bin/env bash
# Five-pair Gloas checks: 512 genesis validators, the head is on Gloas, and each
# Vouch cluster proposed Gloas blocks whose payloads the next block builds on.
set -euo pipefail
[[ $# -eq 1 ]] || { echo "usage: $0 ENCLAVE" >&2; exit 2; }
enclave=$1
beacon="http://$(kurtosis port print "$enclave" cl-2-lighthouse-nethermind http --format ip,number | tr ' ' ':')"
get() { curl -fsS -m 10 "$beacon$1"; }

get /eth/v1/beacon/states/genesis/validators | jq -e '.data | length == 512' >/dev/null
head=$(get /eth/v2/beacon/blocks/head | jq -er 'select(.version == "gloas") | .data.message.slot')
first=$(( $(get /eth/v1/config/spec | jq -r .data.GLOAS_FORK_EPOCH) * 32 ))

# Natives hold indices 0-383; DKG validators follow in cluster order.
cluster() { if (( $1 >= 448 )); then echo b; elif (( $1 >= 384 )); then echo a; fi; }
declare -A proposed revealed
prev_cluster="" prev_hash=""
for slot in $(seq "$first" "$head"); do
  block=$(get "/eth/v2/beacon/blocks/$slot" 2>/dev/null) || continue
  read -r proposer parent hash < <(jq -r '.data.message | [.proposer_index, .body.signed_execution_payload_bid.message.parent_block_hash, .body.signed_execution_payload_bid.message.block_hash] | @tsv' <<<"$block")
  if [[ -n "$prev_cluster" && "$parent" == "$prev_hash" ]]; then revealed[$prev_cluster]=$(( ${revealed[$prev_cluster]:-0} + 1 )); fi
  prev_cluster=$(cluster "$proposer") prev_hash=$hash
  [[ -n "$prev_cluster" ]] && proposed[$prev_cluster]=$(( ${proposed[$prev_cluster]:-0} + 1 ))
done
# The head's payload has no successor yet.
[[ -n "$prev_cluster" ]] && proposed[$prev_cluster]=$(( ${proposed[$prev_cluster]} - 1 ))

for c in a b; do
  echo "cluster $c: ${proposed[$c]:-0} Gloas proposals, ${revealed[$c]:-0} payloads revealed"
  (( ${proposed[$c]:-0} > 0 && ${revealed[$c]:-0} == ${proposed[$c]:-0} ))
done
