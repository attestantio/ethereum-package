# Tempo plain

A mainnet-preset Vouch/Dirk network with 6s slots, plus Tempo and Prometheus/Grafana. It proves Vouch and Dirk both send traces to plain (non-TLS) Tempo.

## Sub-features

- `tempo-plain-vouch`: Tempo holds Vouch spans.
- `tempo-plain-dirk`: Tempo holds Dirk spans.

## How to get to it (user POV)

- `kurtosis run . --args-file .github/tests/tempo-plain.yaml`

## Driving it with kurtosis

Preconditions: a fresh enclave name.

Ready when: the launch exits 0, `doctor.sh` passes and two epochs have passed, so spans exist.

Health epoch: 5.

Steps, between the common Launch/Doctor and Health/Proof steps in [README.md](README.md#common-steps):

- **Assertions.** `.github/tests/assert-tempo-plain.sh "$enclave" > "$run_dir/assert.txt" 2>&1`. Pass: exit 0 (plain receivers, no TLS settings, Vouch and Dirk spans found). Fail: any other exit.

## Gotchas

- Tempo indexes spans with a delay. The script retries for 5 minutes; an immediate manual query can be empty on a healthy run.
