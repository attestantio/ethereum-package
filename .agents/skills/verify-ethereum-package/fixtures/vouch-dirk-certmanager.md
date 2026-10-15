# Vouch/Dirk certmanager

A mainnet-preset network where every validator is on Vouch: two 3-of-5 Dirk clusters, an active/passive pair on cluster A, Lighthouse, Prysm and Lodestar beacon nodes. It proves certificate identity (exact DNS SAN, no CN fallback), certificate validity metrics, successful signing and plain Tempo traces.

## Sub-features

- `cm-images`: the deployed Vouch and Dirk images are the pinned ones.
- `cm-identity`: Dirk accepts Vouch by DNS SAN.
- `cm-metrics`: Vouch exports valid certificate gauges. Released Dirk has none, so Dirk is not checked.
- `cm-signing`: Dirk signs for both clusters and the chain finalizes.

## How to get to it (user POV)

- `kurtosis run . --args-file .github/tests/vouch-dirk-certmanager.yaml`

## Driving it with kurtosis

Preconditions:

- A fresh enclave name and at least 12 GB of free Docker memory: 10 Dirk peers, 3 Vouch instances and 4 EL/CL pairs.

- **Launch.** `kurtosis run . --enclave "$enclave" --args-file .github/tests/vouch-dirk-certmanager.yaml > "$run_dir/launch.log" 2>&1`. Exit 0 also proves `cm-identity`, `cm-metrics`, `cm-signing` and traces: the package runs those checks after first finality, which takes about 30 minutes.
- **Doctor and health.** `doctor.sh` exits 0; after the launch returns, `devnet-health.sh` exits 0.
- **Images.** `.github/tests/assert-certmanager-immutable-images.sh "$enclave" > "$run_dir/assert-images.txt" 2>&1`. Exit 0.
- **Proof.** `setup-after.sh`, `REPORT.md`, `review-page.sh`.

## Gotchas

- Every validator is on Vouch, so the chain finalizes only if Vouch and Dirk work. A stalled chain is a Vouch/Dirk failure until proven otherwise.
- Released Dirk (1.2.1, 1.3.0-rc.1) exports no `certmanager_*` gauges. Restore the Dirk gauge check in `src/certmanager_test/` when a release does.
- `certmanager_test_enabled` rejects image refs without `@sha256:`. On Apple Silicon, run a temporary `registry:2` on `127.0.0.1:5055`, push the arm64 builds, and use `localhost:5055/<image>:<tag>@<digest>` in `args.yaml`. Record the registry container in `resources.md` and remove it by ID. Run the image assertion on a copy with the two refs replaced, and say so in the report.
- The image assertion must match the images pinned in the fixture; update both together.
