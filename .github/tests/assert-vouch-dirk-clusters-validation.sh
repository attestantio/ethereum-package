#!/usr/bin/env bash
set -euo pipefail

fixture=.github/tests/vouch-dirk-clusters.yaml
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"; for enclave in $(kurtosis enclave ls | awk '\''NR > 1 && $2 ~ /^glam150-t2c2-validation-/ { print $2 }'\''); do kurtosis enclave rm -f "$enclave" >/dev/null 2>&1 || true; done' EXIT

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
  if kurtosis run . --enclave "glam150-t2c2-validation-$name" --args-file "$file" --verbosity brief >"$workdir/$name.log" 2>&1; then
    cat "$workdir/$name.log" >&2
    return 1
  fi
  grep -F "$expected" "$workdir/$name.log"
  kurtosis enclave rm -f "glam150-t2c2-validation-$name" >/dev/null
}

run_invalid duplicate "already defined" $'dirk_cluster_id: b|||dirk_cluster_id: a'
run_invalid implicit "Multiple active Vouch creators without dirk_cluster_id" $'dirk_cluster_id: b|||dirk_cluster_id:'
run_invalid invalid-id "must be one lowercase alphanumeric" $'dirk_cluster_id: b|||dirk_cluster_id: aa'
run_invalid missing "references missing" $'validator_count: 0\n    dirk_cluster_id: a|||validator_count: 0\n    dirk_cluster_id: z'
run_invalid threshold "must be between 1" $'dirk_signing_threshold: 2\n\n  - el_type: geth|||dirk_signing_threshold: 4\n\n  - el_type: geth'
run_invalid bounds "outside cluster 'a' bounds" $'validator_count: 0\n    dirk_cluster_id: a\n    vouch_account_start: 0|||validator_count: 0\n    dirk_cluster_id: a\n    vouch_account_start: 1'
run_invalid partial "invalid overlapping account range" $'validator_count: 1\n    dirk_cluster_id: a|||validator_count: 2\n    dirk_cluster_id: a'
run_invalid non-multiinstance "invalid overlapping account range" $'vouch_multiinstance_style: static-delay\n    vouch_multiinstance_attester_delay: 250ms\n    vouch_multiinstance_proposer_delay: 500ms\n    dirk_image:|||vouch_multiinstance_style: \'\'\n    vouch_multiinstance_attester_delay: 250ms\n    vouch_multiinstance_proposer_delay: 500ms\n    dirk_image:'
