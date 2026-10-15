# Vouch/Dirk certmanager

A mainnet-preset network with 12s slots where every validator is on Vouch: two 3-of-5 Dirk clusters, an active/passive pair on cluster A, Lighthouse, Prysm and Lodestar beacon nodes. The package's own certmanager test proves certificate identity (exact DNS SAN, no CN fallback), Vouch certificate validity gauges, successful signing and Tempo traces.

## Sub-features

- `cm-images`: the deployed Vouch and Dirk images are the pinned ones.
- `cm-identity`: every Dirk peer presents its exact DNS SAN.
- `cm-metrics`: Vouch exports valid certificate gauges. Released Dirk has none, so Dirk is not checked.
- `cm-signing`: Vouch and Dirk report successful signing and the chain finalizes.

## How to get to it (user POV)

- `kurtosis run . --args-file .github/tests/vouch-dirk-certmanager.yaml`

## Driving it with kurtosis

Preconditions: a fresh enclave name and at least 12 GB of free Docker memory (10 Dirk peers, 3 Vouch instances, 4 EL/CL pairs).

Ready when: the launch exits 0. The package runs its certmanager checks after first finality, about 30 minutes in, so exit 0 already proves `cm-identity`, `cm-metrics` and `cm-signing`.

Health epoch: 4.

Steps, between the common Launch/Doctor and Health/Proof steps in [README.md](README.md#common-steps):

- **Images.** `.github/tests/assert-certmanager-immutable-images.sh "$enclave" > "$run_dir/assert-images.txt" 2>&1`. Pass: exit 0. Fail: any service runs an image other than the fixture's pin.

## Gotchas

- Every validator is on Vouch, so the chain finalizes only if Vouch and Dirk work. A stalled chain is a Vouch/Dirk failure until proven otherwise.
- Restore the Dirk gauge check in `src/certmanager_test/` when a Dirk release exports `certmanager_*` gauges.
- `certmanager_test_enabled` rejects image refs without `@sha256:`. With the arm64 override, run a temporary `registry:2` on `127.0.0.1:5055`, push the local builds, and use `localhost:5055/<image>:<tag>@<digest>` in `args.yaml`. Record the registry container in `resources.md` and remove it by ID. The image assertion then needs the same refs, so run it on a copy and say so in the report.
