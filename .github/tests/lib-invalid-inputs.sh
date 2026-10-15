#!/usr/bin/env bash
# Sourced by the input-validation scripts. Set `fixture` and `enclave_prefix`
# first, then call run_invalid once per invalid input.
# shellcheck disable=SC2154 # fixture and enclave_prefix come from the caller
#
# run_invalid NAME EXPECTED 'OLD|||NEW' launches the fixture with the first
# OLD replaced by NEW and passes if the launch fails with EXPECTED in its log.

workdir=$(mktemp -d)
created=()
# Remove only the enclaves this script created.
trap 'rm -rf "$workdir"; for enclave in "${created[@]}"; do kurtosis enclave rm -f "$enclave" >/dev/null 2>&1 || true; done' EXIT

run_invalid() {
  local name=$1 expected=$2 replacement=$3
  local file="$workdir/$name.yaml" enclave="$enclave_prefix-$$-$name"
  # Never reuse an existing enclave: the cleanup above would delete it.
  if kurtosis enclave inspect "$enclave" >/dev/null 2>&1; then
    echo "enclave $enclave already exists" >&2
    return 1
  fi
  python3 - "$fixture" "$file" "$replacement" <<'PY'
import sys
source, target, replacement = sys.argv[1:]
text = open(source).read()
old, new = replacement.split('|||', 1)
if old not in text:
    raise SystemExit(f"missing replacement target: {old!r}")
open(target, "w").write(text.replace(old, new, 1))
PY
  created+=("$enclave")
  if kurtosis run . --enclave "$enclave" --args-file "$file" --verbosity brief >"$workdir/$name.log" 2>&1; then
    cat "$workdir/$name.log" >&2
    return 1
  fi
  grep -F "$expected" "$workdir/$name.log"
  kurtosis enclave rm -f "$enclave" >/dev/null
}
