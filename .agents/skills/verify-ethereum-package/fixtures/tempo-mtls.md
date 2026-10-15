# Tempo mTLS

A mainnet-preset Vouch/Dirk network with 6s slots with Tempo behind mTLS, using certificates from a dedicated Tempo CA. It proves Vouch sends traces over mTLS and Dirk tracing is disabled in that mode.

## Sub-features

- `tempo-mtls-vouch`: Tempo holds Vouch spans received over mTLS.
- `tempo-mtls-dirk-off`: Dirk has tracing disabled.

## How to get to it (user POV)

- `kurtosis run . --args-file .github/tests/tempo-mtls.yaml`

## Driving it with kurtosis

Preconditions:

- A fresh enclave name.

- **Launch.** `kurtosis run . --enclave "$enclave" --args-file .github/tests/tempo-mtls.yaml > "$run_dir/launch.log" 2>&1`. Exit 0.
- **Doctor and health.** `doctor.sh` exits 0; after epoch 5, `devnet-health.sh` exits 0.
- **Assertions.** Wait at least two epochs, then `TEMPO_MTLS_EVIDENCE_DIR="$run_dir/mtls" .github/tests/assert-tempo-mtls.sh "$enclave" > "$run_dir/assert.txt" 2>&1`. Exit 0. It checks the Tempo TLS config, that a client without a certificate is rejected, that Vouch's client certificate completes TLS, and that Dirk signed for `vouch-client` (from Dirk metrics).
- **Proof.** `setup-after.sh`, `REPORT.md`, `review-page.sh`.

## Gotchas

- Dirk logs client names only at trace level, and the package runs it at debug. Prove Vouch-to-Dirk traffic from Dirk metrics, not logs.
- Dirk spans are expected to be absent here; their presence is a failure, not extra coverage.
