#!/usr/bin/env bash
# Create the run directory <evidence-root>/<fixture>-<yyyymmdd><letter> with the first free
# letter, write an empty resources.md, and print its path. mkdir is atomic, so two runs never
# share a directory.
# Usage: run_dir="$(new-run.sh <fixture>)" || exit 1
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "usage: $0 <fixture>" >&2
  exit 2
fi
root="${VERIFY_EVIDENCE_DIR:-$HOME/ValidationReviews}"
mkdir -p "$root"
for letter in {a..z}; do
  dir="$root/$1-$(date +%Y%m%d)$letter"
  if mkdir "$dir" 2>/dev/null; then
    printf '# Resources: %s\n\nEverything this run created, by full ID. Remove each by ID at cleanup and set State to removed.\n\n| Type | ID | Created | State |\n|---|---|---|---|\n' "$(basename "$dir")" > "$dir/resources.md"
    echo "$dir"
    exit 0
  fi
done
echo "no free run name for $1 today" >&2
exit 1
