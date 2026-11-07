#!/usr/bin/env bash
# Write SETUP-before.md: what is about to be launched. Run before `kurtosis run`.
# Usage: setup-before.sh <args-file> <evidence-dir>
# Run from the ethereum-package checkout that will be launched. The agent adds a topology
# summary (participants, validator split, Vouch/Dirk layout) under "Topology" afterwards.
# Pass the args file you will launch. A freshness.txt already in <evidence-dir> is embedded.
set -euo pipefail
if [[ $# -ne 2 ]]; then
  echo "usage: $0 <args-file> <evidence-dir>" >&2
  exit 2
fi
args="$1"
dir="$2"
[[ -f "$args" ]] || { echo "args file not found: $args" >&2; exit 2; }
mkdir -p "$dir"
out="$dir/SETUP-before.md"
# Another run's evidence must never be overwritten.
if [[ -e "$out" ]]; then
  echo "$out exists; pick a new run name" >&2
  exit 1
fi
# Written whole or not at all, so a failed run leaves nothing that blocks the next one.
tmp="$(mktemp "$dir/.SETUP-before.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
{
  echo "# SETUP-before: $(basename "$dir")"
  echo
  echo "Recorded $(date -u +%FT%TZ), before launch."
  echo
  echo "## Package"
  echo
  echo "- Checkout: \`$(git rev-parse --show-toplevel)\`"
  echo "- Commit: \`$(git rev-parse HEAD)\` on \`$(git rev-parse --abbrev-ref HEAD)\`"
  changes="$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
  echo "- Tracked changes not committed: $changes"
  echo "- Args file: \`$args\` (sha256 \`$(shasum -a 256 "$args" | cut -c1-16)…\`)"
  echo
  echo "## Topology"
  echo
  echo "_To be filled in by the agent: participants, client per role, validator split, Vouch and Dirk layout._"
  echo
  echo "## Images"
  echo
  echo "| Role | Image |"
  echo "|---|---|"
  # An args file may set no images; the package defaults apply then.
  grep -nE '^[[:space:]]*-?[[:space:]]*[a-z_]*image:[[:space:]]*[^[:space:]]' "$args" | sed -E 's/^([0-9]+):[[:space:]]*-?[[:space:]]*([a-z_]*image):[[:space:]]*"?([^" ]+)"?.*/| \2 (line \1) | `\3` |/' ||
    echo "| all | package defaults |"
  echo
  if [[ -f "$dir/freshness.txt" ]]; then
    echo "## Freshness"
    echo
    echo '```text'
    cat "$dir/freshness.txt"
    echo '```'
    echo
  fi
  echo "## Host"
  echo
  echo "- Docker: $(docker info --format '{{.NCPU}} CPUs, {{.MemTotal}} bytes memory, {{.Architecture}}' 2>/dev/null || echo unavailable)"
  echo "- Kurtosis: $(kurtosis version 2>/dev/null | awk '/CLI Version/ {print $3}')"
  echo "- OTel log stack: $([[ -n "$(docker ps -q --filter name=kurtosis-otel-collector 2>/dev/null)" ]] && echo running || echo "not running")"
  echo
  echo "## Args file"
  echo
  echo '```yaml'
  cat "$args"
  echo '```'
} > "$tmp"
mv "$tmp" "$out"
echo "$out"
