# Tempo mTLS

A mainnet-preset Vouch/Dirk network with 6s slots and Tempo behind mTLS, using certificates from a dedicated Tempo CA. It proves Vouch sends traces over mTLS, Tempo rejects clients without a certificate, and Dirk tracing is off in that mode.

## Sub-features

- `tempo-mtls-vouch`: Tempo holds Vouch spans received over mTLS.
- `tempo-mtls-reject`: a client without a certificate is rejected.
- `tempo-mtls-dirk-off`: Dirk has tracing disabled.

## How to get to it (user POV)

- `kurtosis run . --args-file .github/tests/tempo-mtls.yaml`

## Driving it with kurtosis

Preconditions: a fresh enclave name.

Ready when: the launch exits 0, `doctor.sh` passes and two epochs have passed.

Health epoch: 5.

Steps, between the common Launch/Doctor and Health/Proof steps in [README.md](README.md#common-steps):

- **Assertions.** `TEMPO_MTLS_EVIDENCE_DIR="$run_dir/mtls" .github/tests/assert-tempo-mtls.sh "$enclave" > "$run_dir/assert.txt" 2>&1`. Pass: exit 0 (TLS config and file modes, server SAN, a certificate-less client rejected, Vouch's certificate completes TLS, Dirk signed for `vouch-client`, Vouch spans found). Fail: any other exit.

## Gotchas

- Prove Vouch-to-Dirk traffic from Dirk metrics, not logs (`docs/learnings/vouch-dirk.md`).
- Dirk spans are expected to be absent here; their presence is a failure, not extra coverage.
