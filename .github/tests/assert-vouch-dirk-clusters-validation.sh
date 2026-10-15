#!/usr/bin/env bash
set -euo pipefail

fixture=.github/tests/vouch-dirk-clusters.yaml
enclave_prefix=vouch-dirk-clusters-validation
source .github/tests/lib-invalid-inputs.sh

run_invalid duplicate "already defined" $'dirk_cluster_id: b|||dirk_cluster_id: a'
run_invalid implicit "Multiple active Vouch creators without dirk_cluster_id" $'dirk_cluster_id: b|||dirk_cluster_id:'
run_invalid invalid-id "must be one lowercase alphanumeric" $'dirk_cluster_id: b|||dirk_cluster_id: aa'
run_invalid missing "references missing" $'validator_count: 0\n    dirk_cluster_id: a|||validator_count: 0\n    dirk_cluster_id: z'
run_invalid threshold "must be between 1" $'dirk_signing_threshold: 2\n\n  - el_type: geth|||dirk_signing_threshold: 4\n\n  - el_type: geth'
run_invalid bounds "outside cluster 'a' bounds" $'validator_count: 0\n    dirk_cluster_id: a\n    vouch_account_start: 0|||validator_count: 0\n    dirk_cluster_id: a\n    vouch_account_start: 1'
run_invalid partial "invalid overlapping account range" $'validator_count: 1\n    dirk_cluster_id: a|||validator_count: 2\n    dirk_cluster_id: a'
run_invalid non-multiinstance "invalid overlapping account range" $'vouch_multiinstance_style: static-delay\n    vouch_multiinstance_attester_delay: 250ms\n    vouch_multiinstance_proposer_delay: 500ms\n    dirk_image:|||vouch_multiinstance_style: \'\'\n    vouch_multiinstance_attester_delay: 250ms\n    vouch_multiinstance_proposer_delay: 500ms\n    dirk_image:'
run_invalid pair "must be supplied together" $'vouch_account_count: 1|||vouch_account_count: null'
run_invalid start "must be non-negative" $'vouch_account_start: 0|||vouch_account_start: -1'
run_invalid count "must be positive" $'vouch_account_count: 1|||vouch_account_count: 0'
