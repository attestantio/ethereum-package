# Vouch/Dirk smoke

A mainnet-preset network with 6s slots where one Vouch signs through a 2-of-3 Dirk cluster for a validator created by DKG and placed in genesis. It proves the Vouch/Dirk launcher end to end and is the fixture CI runs.

## Sub-features

- `smoke-genesis`: genesis holds the native validator and the DKG validator, and nothing else.
- `smoke-vouch`: the Vouch service runs.
- `smoke-chain`: the chain finalizes, which needs Vouch's half of the stake.

## How to get to it (user POV)

- `kurtosis run . --args-file .github/tests/vouch-dirk-smoke.yaml`
- CI: the per-PR workflow runs it and then `assert-vouch-dirk-smoke.sh`.

## Driving it with kurtosis

Preconditions: a fresh enclave name, recorded in `resources.md` after launch.

Ready when: the launch exits 0 and `doctor.sh` passes.

- **Launch.** `kurtosis run . --enclave "$enclave" --args-file .github/tests/vouch-dirk-smoke.yaml > "$run_dir/launch.log" 2>&1`. Pass: exit 0. Fail: any other exit; save `launch.log` before anything else.
- **Doctor.** `doctor.sh "$enclave"`. Pass: exit 0. Fail: any FAIL line.
- **Assertions.** `.github/tests/assert-vouch-dirk-smoke.sh "$enclave" > "$run_dir/assert.txt" 2>&1`. Pass: exit 0 (DKG pubkey in genesis, exactly 2 genesis validators, finality within 20 minutes). Fail: any other exit.
- **Health.** After epoch 5, `devnet-health.sh "$enclave" > "$run_dir/health.txt"`. Pass: exit 0. Fail: exit 1 (chain broken) or 2 (a client off the chain, stalled or not finalizing).
- **Proof.** `setup-after.sh`, `REPORT.md`, `review-page.sh`.

## Gotchas

- With one native and one Vouch validator, each holds half the stake. If Vouch stops signing, the chain cannot finalize.
