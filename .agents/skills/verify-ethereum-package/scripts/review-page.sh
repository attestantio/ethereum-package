#!/usr/bin/env bash
# Build <evidence-dir>/index.html from SETUP-before.md, SETUP-after.md and REPORT.md, then open it.
# Usage: review-page.sh <evidence-dir> [--no-open]
# Sign-off status comes from <evidence-dir>/signoff.md. Needs uv.
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 || ! -d "$1" ]]; then
  echo "usage: $0 <evidence-dir> [--no-open]" >&2
  exit 2
fi
dir="$(cd "$1" && pwd)"

uv run -q --with markdown python "$(dirname "$0")/review_page.py" "$dir"

if [[ "${2:-}" != --no-open ]]; then
  opener="$(command -v open || command -v xdg-open || true)"
  if [[ -n "$opener" ]]; then "$opener" "$dir/index.html"; else echo "open $dir/index.html in a browser"; fi
fi
