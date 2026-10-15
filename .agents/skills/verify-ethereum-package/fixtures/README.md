# ethereum-package fixture map

This directory is the maintained source for verifying the package's fixtures. Read this index, then use the matching fixture file as the recipe. Harness rules are in [`../SKILL.md`](../SKILL.md).

## Baseline preconditions

- Docker and the Kurtosis engine are running, and `kurtosis enclave ls` is saved to the run directory.
- The checkout is the one under test; `setup-before.sh` records its commit and uncommitted changes.
- The fixtures use the mainnet preset with 6s slots, because Vouch releases before 1.14 decode SSZ with mainnet sizes only. An epoch takes 3.2 minutes; the first finalized epoch appears after about 4 to 5 epochs.
- **Apple Silicon.** The official `attestant/vouch` and `attestant/dirk` images are amd64 only, and Vouch under emulation trips its deadlock detector on the multi-instance and cluster fixtures. Build arm64 images from the pinned release tags (`docker build -t local/vouch:<version>-<commit> .` in a Vouch checkout at the tag, the same for Dirk), copy the fixture to `$run_dir/args.yaml`, replace the two image refs with the local tags, and launch the copy. Record the substitution in SETUP-before. The certmanager fixture accepts only digest refs; see its file.
- Vouch 1.13.1 logs many `job already exists` errors at the first epoch boundary. It is a known Vouch scheduler bug, fixed after that release; note it in the report, not as a fixture failure.

## Driving conventions

- Launch from the repo root with `kurtosis run . --enclave <name> --args-file .github/tests/<fixture>.yaml`.
- One enclave at a time. Clean it up before launching the next.
- Commands are literal; service names follow `<role>-<n>-<client>-<client>` and come from the live enclave.

## Proof and skip reporting

- Proof is the fixture's assertion script exiting 0, plus `devnet-health.sh` and both setup records.
- A fixture whose assertion script cannot run is blocked, with the reason, not passed.
- Every result names the fixture, the commit and the run directory.

## Generated fixtures

A fixture with a layout in `.github/fixtures/layouts/` is generated. Edit the layout, then run `python3 .github/fixtures/generate-fixture.py`; CI fails on a hand-edited fixture. `python3 .github/fixtures/resolve-images.py mainnet` or `... next-fork <repo> <commit> <devnet>` prints digest-pinned images to paste into the layout. Verify a generated fixture like any other.

## Fixture entry contract

Each file starts with an H1 and one paragraph on what the fixture proves, then four H2s in this order: `Sub-features`, `How to get to it (user POV)`, `Driving it with kurtosis` (`Preconditions:` then labeled bullets pairing action, command and observable result), and `Gotchas`.

## Fixtures

- [Vouch/Dirk smoke](./vouch-dirk-smoke.md): one Vouch with a 2-of-3 Dirk cluster and a DKG validator in genesis. Runs in CI.
- [Vouch/Dirk multi-instance](./vouch-dirk-multiinstance.md): active Vouch with static-delay multi-instance config, plus input validation.
- [Vouch/Dirk clusters](./vouch-dirk-clusters.md): two Dirk clusters, an active/passive pair on cluster A, plus input validation.
- [Tempo plain](./tempo-plain.md): Vouch and Dirk traces in plain Tempo.
- [Tempo mTLS](./tempo-mtls.md): Vouch traces in Tempo over mTLS.
- [Vouch/Dirk certmanager](./vouch-dirk-certmanager.md): mainnet preset, two 3-of-5 Dirk clusters, certificate identity and validity metrics.
