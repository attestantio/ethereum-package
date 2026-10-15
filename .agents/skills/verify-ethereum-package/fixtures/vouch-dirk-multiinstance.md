# Vouch/Dirk multi-instance

A mainnet-preset network with 6s slots and one active Vouch configured for static-delay multi-instance on Dirk cluster A. A second script proves the package rejects invalid multi-instance inputs.

## Sub-features

- `mi-run`: the Vouch runs with static-delay multi-instance, its configured delays and its cluster's single account.
- `mi-validation`: invalid style, a passive Vouch without a cluster or with a missing one, Vouch fields on a non-Vouch participant and a non-kurtosis network all fail at parse time with the expected message.

## How to get to it (user POV)

- `kurtosis run . --args-file .github/tests/vouch-dirk-multiinstance.yaml`

## Driving it with kurtosis

Preconditions: a fresh enclave name.

Ready when: the launch exits 0 and `doctor.sh` passes.

Health epoch: 5.

Steps, between the common Launch/Doctor and Health/Proof steps in [README.md](README.md#common-steps):

- **Assertions.** `.github/tests/assert-vouch-dirk-multiinstance.sh "$enclave" > "$run_dir/assert.txt" 2>&1`. Pass: exit 0 (static-delay, 250ms and 500ms delays, account `DistributedWallet/0` only, starts inactive, chain finalizes). Fail: any other exit.
- **Validation.** `.github/tests/assert-vouch-dirk-multiinstance-validation.sh > "$run_dir/validation.txt" 2>&1`. Pass: exit 0. Fail: an invalid input launched, or failed with a different message. It launches one short enclave per input and removes only those.

## Gotchas

- Static-delay Vouch starts with `attester_active` and `proposer_active` false before arbitration; that is expected.
