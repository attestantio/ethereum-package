#!/usr/bin/env bash
set -euo pipefail

fixture=.github/tests/vouch-dirk-multiinstance.yaml
enclave_prefix=vouch-dirk-mi-validation
source .github/tests/lib-invalid-inputs.sh

run_invalid style "invalid vouch_multiinstance_style" $'vouch_multiinstance_style: static-delay|||vouch_multiinstance_style: invalid'
run_invalid active-range "apply to passive Vouch (validator_count: 0) only" $'dirk_cluster_id: a\n    vouch_multiinstance_style|||dirk_cluster_id: a\n    vouch_account_start: 0\n    vouch_account_count: 1\n    vouch_multiinstance_style'
run_invalid passive-cluster "Passive Vouch requires an explicit dirk_cluster_id" $'validator_count: 1\n    dirk_cluster_id: a|||validator_count: 0\n    dirk_cluster_id: null'
run_invalid passive-range "Passive Vouch requires an explicit account range" $'validator_count: 1\n    dirk_cluster_id: a|||validator_count: 0\n    dirk_cluster_id: a'
run_invalid non-vouch "Vouch configuration fields require vc_type: vouch" $'supernode: true|||supernode: true\n    vouch_default_strategies: true'
