#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC2034 # fixture and enclave_prefix are read by lib-invalid-inputs.sh
fixture=.github/tests/vouch-dirk-multiinstance.yaml
# shellcheck disable=SC2034
enclave_prefix=vouch-dirk-mi-validation
source .github/tests/lib-invalid-inputs.sh

run_invalid duplicate "already defined" $'dirk_cluster_id: b|||dirk_cluster_id: a'
run_invalid implicit "Every active Vouch needs a dirk_cluster_id" $'dirk_cluster_id: b|||dirk_cluster_id:'
run_invalid invalid-id "must be one lowercase alphanumeric" $'dirk_cluster_id: b|||dirk_cluster_id: aa'
run_invalid missing "references missing" $'validator_count: 0\n    dirk_cluster_id: a|||validator_count: 0\n    dirk_cluster_id: z'
run_invalid threshold "must be between 1" $'vouch_multiinstance_attester_delay: 250ms|||dirk_signing_threshold: 4\n    vouch_multiinstance_attester_delay: 250ms'
run_invalid passive-dirk "apply to the active Vouch that creates the cluster" $'vouch_multiinstance_attester_delay: 4s|||dirk_peer_count: 5\n    vouch_multiinstance_attester_delay: 4s'
run_invalid shared-no-multiinstance "so both need vouch_multiinstance_style: static-delay" $'\n    vouch_multiinstance_style: static-delay\n    vouch_multiinstance_attester_delay: 4s\n    vouch_multiinstance_proposer_delay: 2s|||'
run_invalid style "invalid vouch_multiinstance_style" $'vouch_multiinstance_style: static-delay|||vouch_multiinstance_style: invalid'
run_invalid passive-cluster "Passive Vouch requires an explicit dirk_cluster_id" $'validator_count: 0\n    dirk_cluster_id: a|||validator_count: 0\n    dirk_cluster_id: null'
run_invalid non-vouch "Vouch configuration fields require vc_type: vouch" $'supernode: true|||supernode: true\n    vouch_package_strategies: false'
run_invalid network "Vouch participants need network: kurtosis" $'seconds_per_slot: 6|||seconds_per_slot: 6\n  network: sepolia'
run_invalid separate-vc "Vouch runs as a separate VC" $'use_separate_vc: true|||use_separate_vc: false'
run_invalid strategy-name "unknown strategy 'attestationdta'" $'dirk_cluster_id: b|||dirk_cluster_id: b\n    vouch_strategies:\n      attestationdta: {style: first}'
run_invalid strategies-type "vouch_strategies must map a strategy name to its settings" $'dirk_cluster_id: b|||dirk_cluster_id: b\n    vouch_strategies: first'
run_invalid strategy-settings "vouch_strategies.attestationdata must map settings to values" $'dirk_cluster_id: b|||dirk_cluster_id: b\n    vouch_strategies:\n      attestationdata: first'
run_invalid strategy-value "must be a string, number, boolean or list of those" $'dirk_cluster_id: b|||dirk_cluster_id: b\n    vouch_strategies:\n      attestationdata: {style: null}'
run_invalid combinedmajority "combinedmajority.threshold must be 1 or more" $'dirk_cluster_id: b|||dirk_cluster_id: b\n    vouch_strategies:\n      attestationdata: {style: combinedmajority, majority: {threshold: 2}}'
run_invalid combinedmajority-zero "combinedmajority.threshold must be 1 or more" $'dirk_cluster_id: b|||dirk_cluster_id: b\n    vouch_strategies:\n      attestationdata: {style: combinedmajority, combinedmajority: {threshold: 0}}'
run_invalid strategy-mapping "strategies.attestationdata.majority must be a mapping of settings" $'dirk_cluster_id: b|||dirk_cluster_id: b\n    vouch_strategies:\n      attestationdata: {majority: 2}'
run_invalid strategy-duration "strategies.beaconblockproposal.timeout needs a unit" $'dirk_cluster_id: b|||dirk_cluster_id: b\n    vouch_strategies:\n      beaconblockproposal: {timeout: 2}'
run_invalid package-flag "vouch_package_strategies must be true or false" $'dirk_cluster_id: b|||dirk_cluster_id: b\n    vouch_package_strategies: null'
run_invalid delays-no-style "require vouch_multiinstance_style: static-delay" $'dirk_cluster_id: b|||dirk_cluster_id: b\n    vouch_multiinstance_attester_delay: 1s'
