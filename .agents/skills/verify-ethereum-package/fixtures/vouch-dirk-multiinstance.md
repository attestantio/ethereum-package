# Vouch/Dirk multi-instance

A mainnet-preset network with 6s slots and two independent Dirk clusters: cluster A serves an active and a passive Vouch under static-delay multi-instance, and cluster B serves a separate Vouch. A second script proves the package rejects invalid multi-instance and cluster inputs.

## Sub-features

- `mi-active-passive`: active and passive Vouch on cluster A serve the same single account, with longer delays on the passive one. Static-delay instances start inactive until arbitration promotes them.
- `mi-cluster-b`: an independent cluster B with its own Dirk peers and validator.
- `mi-validation`: invalid style, duplicate, missing and invalid cluster IDs, a passive Vouch without a cluster, a bad threshold, Dirk fields on a passive Vouch, a shared cluster without static-delay, delays without static-delay, Vouch fields on a non-Vouch participant, a non-kurtosis network, `use_separate_vc: false` and strategies YAML with package strategies off all fail at parse time with the expected message.

## How to get to it (user POV)

- `kurtosis run . --args-file .github/tests/vouch-dirk-multiinstance.yaml`

## Driving it with kurtosis

Preconditions: a fresh enclave name.

Ready when: the launch exits 0 and `doctor.sh` passes.

Health epoch: 5.

Steps, between the common Launch/Doctor and Health/Proof steps in [README.md](README.md#common-steps):

- **Assertions.** `.github/tests/assert-vouch-dirk-multiinstance.sh "$enclave" > "$run_dir/assert.txt" 2>&1`. Pass: exit 0 (each Vouch talks only to its cluster and lists one account, the configured delays, the active instance starts inactive, DKG validators in genesis, chain finalizes). Fail: any other exit.
- **Validation.** `.github/tests/assert-vouch-dirk-multiinstance-validation.sh > "$run_dir/validation.txt" 2>&1`. Pass: exit 0. Fail: an invalid input launched, or failed with a different message. It launches one short enclave per input and removes only those.

## Gotchas

- The passive Vouch has `validator_count: 0`; it serves all of cluster A's accounts, not its own participant's.
- Static-delay Vouch starts with `attester_active` and `proposer_active` false before arbitration; that is expected.
- The passive instance may activate for a slot. Cluster A's Dirk peers must then deny its duplicate proposal; check `dirk_signer_process_requests_total{request="proposal",result="denied"}` on each `dirk-a-*` peer.
