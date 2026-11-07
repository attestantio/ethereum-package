#!/usr/bin/env bash
# Write SETUP-after.md: what actually ran, captured from the live enclave before cleanup. Read-only.
# Usage: setup-after.sh <enclave> <evidence-dir>
# The record is written whole or not at all, and never over an existing one. A value it could not
# read is written as "unavailable", never as a blank or a default.
set -uo pipefail
if [[ $# -ne 2 ]]; then
  echo "usage: $0 <enclave> <evidence-dir>" >&2
  exit 2
fi
enclave="$1"
source "$(dirname "$0")/lib.sh"
dir="$2"
out="$dir/SETUP-after.md"
inspect="$(inspect_enclave "$enclave" --full-uuids)" || exit 2
if [[ -e "$out" ]]; then
  echo "$out exists; keep it, or pick a new run name" >&2
  exit 1
fi
uuid="$(awk '/^UUID:/ {print $2; exit}' <<<"$inspect")"

# Spec and genesis come from the first beacon node that answers.
base="" spec="" genesis=""
for cl in $(services_of cl "$inspect"); do
  url="$(port_url "$enclave" "$cl" http)"
  if spec="$(curl -fsS -m 5 "$url/eth/v1/config/spec")" && genesis="$(curl -fsS -m 5 "$url/eth/v1/beacon/genesis" | jq -er .data.genesis_time)"; then
    base="$url"
    break
  fi
done
if [[ -z "$base" || ! "$genesis" =~ ^[0-9]+$ ]]; then
  echo "no beacon node of $enclave answered with its spec and genesis; $out not written" >&2
  exit 1
fi

# The output of a command, or "unavailable" when it fails or prints nothing.
val() { local v; v="$("$@" 2>/dev/null)" && [[ -n "$v" && "$v" != null ]] && echo "$v" || echo unavailable; }
cl_version() { curl -fsS -m 5 "$(port_url "$enclave" "$1" http)/eth/v1/node/version" | jq -er .data.version; }
el_version() { el_rpc "$(el_rpc_url "$enclave" "$1")" web3_clientVersion; }
validators() { curl -fsS -m 30 "$base/eth/v1/beacon/states/head/validators" | jq -e '.data | length'; }
at() { date -u -r "$1" +%FT%TZ 2>/dev/null || date -u -d "@$1" +%FT%TZ; }

report() {
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
  for cl in $(services_of cl "$inspect"); do echo "- $cl: $(val cl_version "$cl")"; done
  for el in $(services_of el "$inspect"); do echo "- $el: $(val el_version "$el")"; done
  echo
  echo "## Served network"
  echo
  jq -r '.data | "- Preset \(.PRESET_BASE // "unavailable"), config \(.CONFIG_NAME // "unavailable"), deposit chain ID \(.DEPOSIT_CHAIN_ID // "unavailable"), \(.SECONDS_PER_SLOT // "unavailable")s slots, \(.SLOTS_PER_EPOCH // "unavailable") slots per epoch\n- Fork epochs: \([to_entries[] | select(.key|endswith("_FORK_EPOCH")) | "\(.key|sub("_FORK_EPOCH";""))=\(.value)"] | join(", "))"' <<<"$spec"
  echo "- Genesis: $(at "$genesis")"
  echo "- Validators at head: $(val validators)"
  genesis_files="$(mktemp -d)"
  if kurtosis files download "$enclave" el_cl_genesis_data "$genesis_files" >/dev/null 2>&1; then
    echo "- \`bootstrap_nodes.txt\`: $(wc -c < "$genesis_files/bootstrap_nodes.txt" | tr -d ' ') bytes"
  else
    echo "- \`bootstrap_nodes.txt\`: not available"
  fi
  rm -rf "$genesis_files"
  echo
  echo "## Differences from SETUP-before"
  echo
  echo "_To be filled in by the agent after comparing both files._"
}

mkdir -p "$dir"
tmp="$(mktemp "$dir/.SETUP-after.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
report > "$tmp" && mv "$tmp" "$out" && echo "$out"
