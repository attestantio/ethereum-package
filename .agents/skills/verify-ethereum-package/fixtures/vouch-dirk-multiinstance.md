# Vouch/Dirk multi-instance

A mainnet-preset network with 6s slots and one Vouch configured for static-delay multi-instance over an explicit account range on Dirk cluster A. A second script proves the package rejects invalid multi-instance inputs.

## Sub-features

- `mi-run`: the multi-instance Vouch runs with its configured delays and account range.
- `mi-validation`: invalid style, unpaired range, negative start, zero count, passive without cluster or range, and Vouch fields on a non-Vouch participant all fail at parse time with the expected message.

## How to get to it (user POV)

- `kurtosis run . --args-file .github/tests/vouch-dirk-multiinstance.yaml`

## Driving it with kurtosis

Preconditions:

- A fresh enclave name.

- **Launch.** `kurtosis run . --enclave "$enclave" --args-file .github/tests/vouch-dirk-multiinstance.yaml > "$run_dir/launch.log" 2>&1`. Exit 0.
- **Doctor and health.** `doctor.sh` exits 0; after epoch 5, `devnet-health.sh` exits 0.
- **Rendered config.** Download the Vouch config artifact (`kurtosis files download "$enclave" vouch-config-1 "$run_dir/vouch-config"`). It has `multiinstance.style: static-delay`, attester delay `250ms`, proposer delay `500ms` and account `0` only.
- **Validation.** Run `.github/tests/assert-vouch-dirk-multiinstance-validation.sh > "$run_dir/validation.txt" 2>&1`. Exit 0. It launches one short enclave per invalid input and removes each.
- **Proof.** `setup-after.sh`, `REPORT.md`, `review-page.sh`.

## Gotchas

- The amd64 Vouch image crashes under emulation here (deadlock detector). Use the arm64 override on Apple Silicon.
- Static-delay Vouch starts with `attester_active` and `proposer_active` false before arbitration; that is expected.
- The validation script creates and deletes its own enclaves. Run it only while no other run is using its enclave names.
