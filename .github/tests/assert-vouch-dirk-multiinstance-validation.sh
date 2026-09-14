#!/usr/bin/env bash
set -euo pipefail

fixture=.github/tests/vouch-dirk-multiinstance.yaml
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"; for enclave in $(kurtosis enclave ls | awk '\''NR > 1 && $2 ~ /^glam150-t2c1-validation-/ { print $2 }'\''); do kurtosis enclave rm -f "$enclave" >/dev/null 2>&1 || true; done' EXIT

run_invalid() {
  local name=$1 expected=$2 replacement=$3
  local file="$workdir/$name.yaml"
  python3 - "$fixture" "$file" "$replacement" <<'PY'
import sys
source, target, replacement = sys.argv[1:]
text = open(source).read()
old, new = replacement.split('|||', 1)
if old not in text:
    raise SystemExit(f"missing replacement target: {old!r}")
open(target, "w").write(text.replace(old, new, 1))
PY
  if kurtosis run . --enclave "glam150-t2c1-validation-$name" --args-file "$file" --verbosity brief >"$workdir/$name.log" 2>&1; then
    cat "$workdir/$name.log" >&2
    return 1
  fi
  grep -F "$expected" "$workdir/$name.log"
  kurtosis enclave rm -f "glam150-t2c1-validation-$name" >/dev/null
}

run_invalid style "invalid vouch_multiinstance_style" $'vouch_multiinstance_style: static-delay|||vouch_multiinstance_style: invalid'
run_invalid pair "must be supplied together" $'vouch_account_count: 1|||vouch_account_count: null'
run_invalid start "must be non-negative" $'vouch_account_start: 0|||vouch_account_start: -1'
run_invalid count "must be positive" $'vouch_account_count: 1|||vouch_account_count: 0'
run_invalid passive-cluster "Passive Vouch requires an explicit dirk_cluster_id" $'validator_count: 1\n    dirk_cluster_id: a|||validator_count: 0\n    dirk_cluster_id: null'
run_invalid passive-range "Passive Vouch requires an explicit account range" $'validator_count: 1\n    dirk_cluster_id: a\n    vouch_account_start: 0\n    vouch_account_count: 1|||validator_count: 0\n    dirk_cluster_id: a\n    vouch_account_start: null\n    vouch_account_count: null'
run_invalid non-vouch "Vouch configuration fields require vc_type: vouch" $'supernode: true|||supernode: true\n    vouch_default_strategies: true'
