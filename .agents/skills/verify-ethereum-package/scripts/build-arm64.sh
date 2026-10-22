#!/usr/bin/env bash
# Build a local arm64 image of an Attestant client at the release the args file pins, for hosts
# where the official image is amd64 only. The tag ends with the run name, so it never replaces
# another run's image. Prints `<client>_ref=... <client>_id=...` for eval, and records the image in
# the run's resources.md when it exists. Remove the image by ID at cleanup.
# Usage: eval "$(build-arm64.sh <vouch|dirk> <args-file> <run>)"
set -euo pipefail
if [[ $# -ne 3 || ! "$1" =~ ^(vouch|dirk)$ ]]; then
  echo "usage: $0 <vouch|dirk> <args-file> <run>" >&2
  exit 2
fi
client="$1"
run="$3"
version="$(grep -oE "attestant/$client:[^@\" ]+" "$2" | head -1 | cut -d: -f2 || true)"
[[ -n "$version" ]] || { echo "$2 pins no attestant/$client image" >&2; exit 1; }
version="${version#v}"
src="$(mktemp -d)"
trap 'rm -rf "$src"' EXIT
# A shallow clone of an annotated tag warns "is not a commit"; it is harmless.
git -c advice.detachedHead=false clone -q --depth 1 --branch "v$version" "https://github.com/attestantio/$client" "$src" 2> >(grep -v "is not a commit" >&2)
ref="local/$client:$version-$(git -C "$src" rev-parse --short=7 HEAD)-$run"
if docker image inspect "$ref" >/dev/null 2>&1; then
  echo "$ref already exists; pick a new run name" >&2
  exit 1
fi
docker build -q -t "$ref" "$src" >/dev/null
id="$(docker image inspect "$ref" --format '{{.Id}}')"
resources="${VERIFY_EVIDENCE_DIR:-$HOME/ValidationReviews}/$run/resources.md"
[[ -f "$resources" ]] && echo "| image | $ref $id | $(date -u +%FT%TZ) | present |" >> "$resources"
echo "${client}_ref=$ref ${client}_id=$id"
