# Vouch/Dirk multi-instance

A mainnet-preset network with 6s slots and one active Vouch configured for static-delay multi-instance on Dirk cluster A. A second script proves the package rejects invalid multi-instance inputs.

## Sub-features

- `mi-run`: the Vouch runs with static-delay multi-instance, its configured delays and its cluster's single account.
- `mi-validation`: invalid style, an account range on an active Vouch, passive without cluster or range, and Vouch fields on a non-Vouch participant all fail at parse time with the expected message.

## How to get to it (user POV)

- `kurtosis run . --args-file .github/tests/vouch-dirk-multiinstance.yaml`

## Driving it with kurtosis

Preconditions: a fresh enclave name.

Ready when: the launch exits 0 and `doctor.sh` passes.

- **Launch.** `kurtosis run . --enclave "$enclave" --args-file .github/tests/vouch-dirk-multiinstance.yaml > "$run_dir/launch.log" 2>&1`. Pass: exit 0. Fail: any other exit; save `launch.log` before anything else.
- **Doctor.** `doctor.sh "$enclave"`. Pass: exit 0. Fail: any FAIL line.
- **Assertions.** `.github/tests/assert-vouch-dirk-multiinstance.sh "$enclave" > "$run_dir/assert.txt" 2>&1`. Pass: exit 0 (static-delay, 250ms and 500ms delays, account `DistributedWallet/0` only, starts inactive). Fail: any other exit.
- **Validation.** `.github/tests/assert-vouch-dirk-multiinstance-validation.sh > "$run_dir/validation.txt" 2>&1`. Pass: exit 0. Fail: an invalid input launched, or failed with a different message. It launches one short enclave per input and removes only those.
- **Health.** After epoch 5, `devnet-health.sh "$enclave" > "$run_dir/health.txt"`. Pass: exit 0. Fail: exit 1 (chain broken) or 2 (a client off the chain, stalled or not finalizing).
- **Proof.** `setup-after.sh`, `REPORT.md`, `review-page.sh`.

## Gotchas

- Static-delay Vouch starts with `attester_active` and `proposer_active` false before arbitration; that is expected.
