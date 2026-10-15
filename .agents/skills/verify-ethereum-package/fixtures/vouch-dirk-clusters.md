# Vouch/Dirk clusters

A mainnet-preset network with 6s slots and two independent Dirk clusters: cluster A serves an active and a passive Vouch sharing one account range, and cluster B serves a separate Vouch. A second script proves the package rejects invalid cluster and account-range inputs.

## Sub-features

- `clusters-a`: active and passive Vouch on cluster A share the same account range.
- `clusters-b`: an independent cluster B with its own Dirk peers and validator.
- `clusters-validation`: invalid cluster IDs, thresholds, bounds, overlaps and account ranges fail at parse time.

## How to get to it (user POV)

- `kurtosis run . --args-file .github/tests/vouch-dirk-clusters.yaml`

## Driving it with kurtosis

Preconditions: a fresh enclave name.

Ready when: the launch exits 0 and `doctor.sh` passes.

- **Launch.** `kurtosis run . --enclave "$enclave" --args-file .github/tests/vouch-dirk-clusters.yaml > "$run_dir/launch.log" 2>&1`. Pass: exit 0. Fail: any other exit; save `launch.log` before anything else.
- **Doctor.** `doctor.sh "$enclave"`. Pass: exit 0. Fail: any FAIL line.
- **Assertions.** `.github/tests/assert-vouch-dirk-clusters.sh "$enclave" > "$run_dir/assert.txt" 2>&1`. Pass: exit 0 (each Vouch talks only to its cluster, DKG validators in genesis). Fail: any other exit.
- **Validation.** `.github/tests/assert-vouch-dirk-clusters-validation.sh > "$run_dir/validation.txt" 2>&1`. Pass: exit 0. Fail: an invalid input launched, or failed with a different message.
- **Health.** After epoch 5, `devnet-health.sh "$enclave" > "$run_dir/health.txt"`. Pass: exit 0. Fail: exit 1 (chain broken) or 2 (a client off the chain, stalled or not finalizing).
- **Proof.** `setup-after.sh`, `REPORT.md`, `review-page.sh`.

## Gotchas

- The passive Vouch has `validator_count: 0`; its duties come from cluster A's range, not its own participant.
