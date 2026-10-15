# Tempo plain

A mainnet-preset Vouch/Dirk network with 6s slots with the Tempo and Prometheus/Grafana services. It proves Vouch and Dirk both send traces to plain (non-TLS) Tempo.

## Sub-features

- `tempo-plain-vouch`: Tempo holds Vouch spans.
- `tempo-plain-dirk`: Tempo holds Dirk spans.

## How to get to it (user POV)

- `kurtosis run . --args-file .github/tests/tempo-plain.yaml`

## Driving it with kurtosis

Preconditions:

- A fresh enclave name.

- **Launch.** `kurtosis run . --enclave "$enclave" --args-file .github/tests/tempo-plain.yaml > "$run_dir/launch.log" 2>&1`. Exit 0.
- **Doctor and health.** `doctor.sh` exits 0; after epoch 5, `devnet-health.sh` exits 0.
- **Assertions.** Wait at least two epochs so spans exist, then `.github/tests/assert-tempo-plain.sh "$enclave" > "$run_dir/assert.txt" 2>&1`. Exit 0.
- **Proof.** `setup-after.sh`, `REPORT.md`, `review-page.sh`.

## Gotchas

- Tempo indexes spans with a delay. An immediate query can be empty on a healthy run.
