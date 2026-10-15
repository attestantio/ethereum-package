#!/usr/bin/env bash
# Write SETUP-before.md: what is about to be launched. Run before `kurtosis run`.
# Usage: setup-before.sh <args-file> <evidence-dir>
# Run from the ethereum-package checkout that will be launched. The agent adds a topology
# summary (participants, validator split, Vouch/Dirk layout) under "Topology" afterwards.
set -euo pipefail
if [[ $# -ne 2 ]]; then
  echo "usage: $0 <args-file> <evidence-dir>" >&2
  exit 64
fi
args="$1"
dir="$2"
mkdir -p "$dir"
out="$dir/SETUP-before.md"
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
  grep -nE '^\s*-?\s*[a-z_]*image:\s*\S' "$args" | sed -E 's/^([0-9]+):\s*-?\s*([a-z_]*image):\s*"?([^" ]+)"?.*/| \2 (line \1) | `\3` |/'
  echo
  echo "## Host"
  echo
  echo "- Docker: $(docker info --format '{{.NCPU}} CPUs, {{.MemTotal}} bytes memory, {{.Architecture}}')"
  echo "- Kurtosis: $(kurtosis version 2>/dev/null | awk '/CLI Version/ {print $3}')"
  echo
  echo "## Args file"
  echo
  echo '```yaml'
  cat "$args"
  echo '```'
} > "$out"
echo "$out"
