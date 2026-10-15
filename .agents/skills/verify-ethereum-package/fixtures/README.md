# ethereum-package fixture map

This directory is the maintained source for verifying the package's fixtures. Read this index, then use the matching fixture file as the recipe. Harness rules are in [`../SKILL.md`](../SKILL.md).

## Baseline preconditions

- Docker and the Kurtosis engine are running, and `kurtosis enclave ls` is saved to the run directory.
- The checkout is the one under test; `setup-before.sh` records its commit and uncommitted changes.
- Vouch fixtures use the mainnet preset (why: `docs/learnings/vouch-dirk.md`). With 6s slots an epoch takes 3.2 minutes; with 12s, 6.4.
- **amd64-only images.** `resolve-images.py` prints each image's platforms. If the host is arm64 and an image has no `linux/arm64` build (today: `attestant/vouch`, `attestant/dirk`), build one from the same release tag (`docker build -t local/<image>:<version>-<commit> .` in a checkout at the tag), copy the fixture to `$run_dir/args.yaml`, replace the refs with the local tags, and launch the copy. Record the substitution in SETUP-before. Emulation is not a substitute: Vouch under emulation trips its deadlock detector. For digest-only fixtures, see the certmanager file.
- Vouch 1.13.1 logs many `job already exists` errors at the first epoch boundary. It is a known Vouch scheduler bug, fixed after that release; note it in the report, not as a fixture failure.

## Driving conventions

- Launch from the repo root with `kurtosis run . --enclave <name> --args-file .github/tests/<fixture>.yaml`.
- One enclave at a time. Clean it up before launching the next.
- Service names come from the live enclave: `el-<n>-<el>-<cl>`, `cl-<n>-<cl>-<el>`, `vc-<n>-<el>-<cl>-<vc>`, `dirk-<cluster>-<n>` (or `dirk-<n>`), `tempo`.

## Proof and skip reporting

- Proof is every step of the fixture's recipe passing, plus `devnet-health.sh` and both setup records.
- A step whose precondition never happened is blocked, with the reason, not passed.
- Every result names the fixture, the commit and the run directory.

## Generated fixtures

A fixture with a layout in `.github/fixtures/layouts/` is generated. Edit the layout, then run `python3 .github/fixtures/generate-fixture.py`; CI fails on a hand-edited fixture. `python3 .github/fixtures/resolve-images.py mainnet` or `... next-fork <repo> <commit> <devnet>` prints digest-pinned images to paste into the layout. Verify a generated fixture like any other.

## Common steps

Every recipe runs these steps around its own:

1. **Launch.** `kurtosis run . --enclave "$enclave" --args-file .github/tests/<fixture>.yaml > "$run_dir/launch.log" 2>&1`. Pass: exit 0. Fail: any other exit; save `launch.log` before anything else.
2. **Doctor.** `doctor.sh "$enclave"`. Pass: exit 0. Fail: any FAIL line.
3. The recipe's own steps.
4. **Health.** After the recipe's health epoch, `devnet-health.sh "$enclave" > "$run_dir/health.txt"`. Pass: exit 0. Fail: 1 (no healthy majority chain), 3 (a client off the chain, stalled or not finalizing); 2 means the check could not run.
5. **Proof.** `setup-after.sh`, `REPORT.md`, `review-page.sh`.

## Fixture entry contract

Each file starts with an H1 and one paragraph on what the fixture proves, then four H2s in this order: `Sub-features`, `How to get to it (user POV)`, `Driving it with kurtosis`, and `Gotchas`. The driving section states `Preconditions:`, `Ready when:` and `Health epoch:`, then one bullet per fixture-specific step naming the command, what passes and what fails.

## Fixtures

- [Vouch/Dirk smoke](./vouch-dirk-smoke.md): one Vouch with a 2-of-3 Dirk cluster and a DKG validator in genesis. Runs in CI.
- [Vouch/Dirk multi-instance](./vouch-dirk-multiinstance.md): active Vouch with static-delay multi-instance config, plus input validation.
- [Vouch/Dirk clusters](./vouch-dirk-clusters.md): two Dirk clusters, an active/passive pair on cluster A, plus input validation.
- [Tempo plain](./tempo-plain.md): Vouch and Dirk traces in plain Tempo.
- [Tempo mTLS](./tempo-mtls.md): Vouch traces in Tempo over mTLS.
- [Vouch/Dirk certmanager](./vouch-dirk-certmanager.md): two 3-of-5 Dirk clusters, certificate identity and validity metrics.
