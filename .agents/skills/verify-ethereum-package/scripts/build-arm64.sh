#!/usr/bin/env bash
# Build a local arm64 image of an Attestant client from its release tag, for hosts where the
# official image is amd64 only. The tag ends with the run name, so it never replaces another
# run's image. Prints the image ref and ID; record both in resources.md and remove by ID.
# Usage: build-arm64.sh <vouch|dirk> <version> <run>     e.g. build-arm64.sh vouch 1.14.0-alpha.2 five-pair-20261021b
set -euo pipefail
if [[ $# -ne 3 || ! "$1" =~ ^(vouch|dirk)$ ]]; then
  echo "usage: $0 <vouch|dirk> <version> <run>" >&2
  exit 2
fi
client="$1"
version="${2#v}"
run="$3"
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
echo "$ref $(docker image inspect "$ref" --format '{{.Id}}')"
