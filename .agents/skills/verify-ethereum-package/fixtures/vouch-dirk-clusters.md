# Vouch/Dirk clusters

A mainnet-preset network with 6s slots and two independent Dirk clusters: cluster A serves an active and a passive Vouch sharing one account range, and cluster B serves a separate Vouch. A second script proves the package rejects invalid cluster inputs.

## Sub-features

- `clusters-a`: active and passive Vouch on cluster A share the same account range.
- `clusters-b`: an independent cluster B with its own Dirk peers and validator.
- `clusters-validation`: invalid cluster inputs fail at parse time.

## How to get to it (user POV)

- `kurtosis run . --args-file .github/tests/vouch-dirk-clusters.yaml`

## Driving it with kurtosis

Preconditions:

- A fresh enclave name.

- **Launch.** `kurtosis run . --enclave "$enclave" --args-file .github/tests/vouch-dirk-clusters.yaml > "$run_dir/launch.log" 2>&1`. Exit 0.
- **Doctor and health.** `doctor.sh` exits 0; after epoch 5, `devnet-health.sh` exits 0.
- **Assertions.** `.github/tests/assert-vouch-dirk-clusters.sh "$enclave" > "$run_dir/assert.txt" 2>&1`. Exit 0.
- **Validation.** `.github/tests/assert-vouch-dirk-clusters-validation.sh > "$run_dir/validation.txt" 2>&1`. Exit 0.
- **Proof.** `setup-after.sh`, `REPORT.md`, `review-page.sh`.

## Gotchas

- Use the arm64 override on Apple Silicon; the amd64 Vouch crashes under emulation.
- The passive Vouch has `validator_count: 0`; its duties come from cluster A's range, not its own participant.
