#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC2034 # fixture and enclave_prefix are read by lib-invalid-inputs.sh
fixture=.github/tests/vouch-dirk-multiinstance.yaml
# shellcheck disable=SC2034
enclave_prefix=vouch-dirk-mi-validation
source .github/tests/lib-invalid-inputs.sh

run_invalid style "invalid vouch_multiinstance_style" $'vouch_multiinstance_style: static-delay|||vouch_multiinstance_style: invalid'
run_invalid passive-cluster "Passive Vouch requires an explicit dirk_cluster_id" $'validator_count: 1\n    dirk_cluster_id: a|||validator_count: 0\n    dirk_cluster_id: null'
run_invalid passive-missing "references missing dirk_cluster_id 'a'" $'validator_count: 1\n    dirk_cluster_id: a|||validator_count: 0\n    dirk_cluster_id: a'
run_invalid non-vouch "Vouch configuration fields require vc_type: vouch" $'supernode: true|||supernode: true\n    vouch_package_strategies: false'
run_invalid network "Vouch participants need network: kurtosis" $'seconds_per_slot: 6|||seconds_per_slot: 6\n  network: sepolia'
run_invalid separate-vc "Vouch runs as a separate VC" $'use_separate_vc: true|||use_separate_vc: false'
run_invalid strategies-off "no effect with vouch_package_strategies: false" $'use_separate_vc: true|||use_separate_vc: true\n    vouch_package_strategies: false\n    vouch_strategies_yaml: "strategies: {}"'
run_invalid delays-no-style "require vouch_multiinstance_style: static-delay" $'vouch_multiinstance_style: static-delay|||vouch_multiinstance_style: ""'
