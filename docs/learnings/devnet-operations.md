# Devnet operations

## Finality

Justification is skipped while `current_epoch <= 1`. Epoch 2 is the first that can be justified, and the first finality lands at the epoch 4 boundary: about 26 minutes at 12s slots, 13 at 6s. A chain with no finality before epoch 5 is normal; investigate after that.

## Vouch signing

- Vouch at info level logs no per-duty results. Prove signing from its metrics, for example `vouch_attestation_process_requests_total{result="succeeded"}` and `vouch_beaconblockproposal_process_requests_total`.
- `BLOCK_ERROR_ALREADY_KNOWN` in Vouch logs is normal. The multinode submitter sends every block to all beacon nodes, and some already have it from gossip.
- Static-delay multi-instance with equal attester delays lets the same instance win every race. Give active and passive instances different delays.

## Assertoor

- `stability-check` can fail with "context canceled" on a healthy chain; it is an Assertoor timeout.
- `block-proposal-check` is the reliable way to confirm every client pair proposed.
- Confirm finality directly: `curl <beacon>/eth/v1/beacon/states/head/finality_checkpoints`.

## Devnet metadata

An ethpandaops devnet's CL `config.yaml` lists only the final blob schedule entry per epoch, so steps that share an epoch collapse into one. Its EL `genesis.json` lists every BPO step with target, max, base-fee fraction and activation time; read blob settings from there.

## Local images

Kurtosis uses locally tagged images without a registry. The arm64 override for amd64-only Vouch and Dirk images, and the registry workaround for digest-only fixtures, are in `.agents/skills/verify-ethereum-package/fixtures/README.md`.
