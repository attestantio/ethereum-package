# Vouch/Dirk clusters

A mainnet-preset network with 6s slots and two independent Dirk clusters: cluster A serves an active and a passive Vouch, and cluster B serves a separate Vouch. A second script proves the package rejects invalid cluster inputs.

## Sub-features

- `clusters-a`: active and passive Vouch on cluster A serve the same accounts, with longer delays on the passive one.
- `clusters-b`: an independent cluster B with its own Dirk peers and validator.
- `clusters-validation`: duplicate, missing and invalid cluster IDs, a bad threshold, Dirk fields on a passive Vouch and a shared cluster without static-delay fail at parse time.

## How to get to it (user POV)

- `kurtosis run . --args-file .github/tests/vouch-dirk-clusters.yaml`

## Driving it with kurtosis

Preconditions: a fresh enclave name.

Ready when: the launch exits 0 and `doctor.sh` passes.

Health epoch: 5.

Steps, between the common Launch/Doctor and Health/Proof steps in [README.md](README.md#common-steps):

- **Assertions.** `.github/tests/assert-vouch-dirk-clusters.sh "$enclave" > "$run_dir/assert.txt" 2>&1`. Pass: exit 0 (each Vouch talks only to its cluster, DKG validators in genesis). Fail: any other exit.
- **Validation.** `.github/tests/assert-vouch-dirk-clusters-validation.sh > "$run_dir/validation.txt" 2>&1`. Pass: exit 0. Fail: an invalid input launched, or failed with a different message.

## Gotchas

- The passive Vouch has `validator_count: 0`; it serves all of cluster A's accounts, not its own participant's.
