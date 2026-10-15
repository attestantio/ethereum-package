# Vouch/Dirk smoke

A mainnet-preset network with 6s slots where one Vouch signs through a 2-of-3 Dirk cluster for a validator created by DKG and placed in genesis. It proves the Vouch/Dirk launcher end to end and is the fixture CI runs.

## Sub-features

- `smoke-genesis`: genesis holds the native validator and the DKG validator, and nothing else.
- `smoke-vouch`: the Vouch service runs.
- `smoke-chain`: the chain advances and finalizes on both beacon nodes.

## How to get to it (user POV)

- `kurtosis run . --args-file .github/tests/vouch-dirk-smoke.yaml`
- CI: the per-PR workflow runs it and then `assert-vouch-dirk-smoke.sh`.

## Driving it with kurtosis

Preconditions:

- A fresh enclave name, recorded in `resources.md` after launch.

- **Launch.** Run `kurtosis run . --enclave "$enclave" --args-file .github/tests/vouch-dirk-smoke.yaml > "$run_dir/launch.log" 2>&1`. Exit 0.
- **Doctor.** Run `doctor.sh "$enclave"`. Exit 0.
- **Assertions.** Run `.github/tests/assert-vouch-dirk-smoke.sh "$enclave" > "$run_dir/assert.txt" 2>&1`. Exit 0: the DKG pubkey is in the genesis validator set, genesis has exactly 2 validators, and the chain finalizes within 20 minutes.
- **Health.** After epoch 5, run `devnet-health.sh "$enclave" > "$run_dir/health.txt"`. Exit 0 with a finalized epoch.
- **Proof.** `setup-after.sh`, `REPORT.md`, `review-page.sh`.

## Gotchas

- On the minimal preset, Vouch 1.13.1 fails to decode every proposal and the chain never finalizes. Keep the mainnet preset until the pinned Vouch is 1.14 or newer.
- With one native and one Vouch validator, each holds half the stake. If Vouch stops signing, the chain cannot finalize.
