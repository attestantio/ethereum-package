#!/usr/bin/env bash
# Write SETUP-after.md: what actually ran, captured from the live enclave before cleanup. Read-only.
# Usage: setup-after.sh <enclave> <evidence-dir>
set -uo pipefail
if [[ $# -ne 2 ]]; then
  echo "usage: $0 <enclave> <evidence-dir>" >&2
  exit 2
fi
enclave="$1"
source "$(dirname "$0")/lib.sh"
dir="$2"
mkdir -p "$dir"
out="$dir/SETUP-after.md"
inspect="$(kurtosis enclave inspect --full-uuids "$enclave" 2>/dev/null)"
uuid="$(awk '/^UUID:/ {print $2; exit}' <<<"$inspect")"
rpc() { curl -fsS -m 5 -X POST -H 'Content-Type: application/json' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":[]}" "$1" | jq -r .result; }
{
  echo "# SETUP-after: $(basename "$dir")"
  echo
  echo "Captured from enclave \`$enclave\` (\`$uuid\`) at $(date -u +%FT%TZ), before cleanup."
  echo
  echo "## Deployed services"
  echo
  echo "| Service | Image | Image ID | State |"
  echo "|---|---|---|---|"
  for id in $(docker ps -aq --no-trunc --filter "label=kurtosis_enclave_name=$enclave"); do
    docker inspect "$id" | jq -r '.[0] | "| \(.Config.Labels.kurtosis_service_name) | `\(.Config.Image)` | `\(.Image[0:19])…` | \(.State.Status) |"'
  done | sort
  echo
  echo "## Reported versions"
  echo
  for cl in $(services_of cl "$inspect"); do
    echo "- $cl: $(curl -fsS -m 5 "$(port_url "$enclave" "$cl" http)/eth/v1/node/version" | jq -r .data.version)"
  done
  for el in $(services_of el "$inspect"); do
    echo "- $el: $(rpc "$(port_url "$enclave" "$el" rpc)" web3_clientVersion)"
  done
  echo
  echo "## Served network"
  echo
  cl1="$(services_of cl "$inspect" | head -1)"
  b="$(port_url "$enclave" "$cl1" http)"
  curl -fsS -m 5 "$b/eth/v1/config/spec" | jq -r '.data | "- Preset \(.PRESET_BASE), config \(.CONFIG_NAME), deposit chain ID \(.DEPOSIT_CHAIN_ID), \(.SECONDS_PER_SLOT)s slots, \(.SLOTS_PER_EPOCH) slots per epoch\n- Fork epochs: \([to_entries[] | select(.key|endswith("_FORK_EPOCH")) | "\(.key|sub("_FORK_EPOCH";""))=\(.value)"] | join(", "))"'
  g="$(curl -fsS -m 5 "$b/eth/v1/beacon/genesis" | jq -r .data.genesis_time)"
  echo "- Genesis: $(date -u -r "$g" +%FT%TZ 2>/dev/null || date -u -d "@$g" +%FT%TZ)"
  echo "- Validators at head: $(curl -fsS -m 30 "$b/eth/v1/beacon/states/head/validators" | jq '.data | length')"
  tmp="$(mktemp -d)"
  if kurtosis files download "$enclave" el_cl_genesis_data "$tmp" >/dev/null 2>&1; then
    echo "- \`bootstrap_nodes.txt\`: $(wc -c < "$tmp/bootstrap_nodes.txt" | tr -d ' ') bytes"
  else
    echo "- \`bootstrap_nodes.txt\`: not available"
  fi
  rm -rf "$tmp"
  echo
  echo "## Differences from SETUP-before"
  echo
  echo "_To be filled in by the agent after comparing both files._"
} > "$out"
echo "$out"
