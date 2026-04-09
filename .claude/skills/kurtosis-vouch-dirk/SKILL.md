---
name: kurtosis-vouch-dirk
description: Deploy and manage Vouch+Dirk Ethereum devnets using Kurtosis on the attestantio/ethereum-package fork. Use when spinning up local devnets with distributed validator technology (Vouch as validator client, Dirk as distributed threshold signer), testing Vouch/Dirk code changes, building local Docker images from fix branches, debugging devnet issues (finalization, attestation failures, sync committee errors), querying distributed traces via Tempo, or performing teardown/rebuild cycles after code changes. Covers multi-cluster Dirk architecture, multi-instance HA failover, account range partitioning, and devnet verification workflows.
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# Kurtosis Vouch/Dirk Devnet

Deploy Ethereum devnets with Vouch + Dirk via Kurtosis (`feat/add-vouch-dirk` branch).

## Build

```bash
docker build -t vouch:local /Users/miguel-attestant/Documents/Projects/vouch
docker build -t dirk:local /Users/miguel-attestant/Documents/Projects/dirk
```

Use `--no-cache` when switching base image versions. Images are picked up locally by Kurtosis.

## Deploy

| Config | Use case |
|--------|----------|
| `vouch-dirk-all-clients.yaml` | Full: 2 clusters, 10 Dirk, 3 Vouch, 5 CL clients, Tempo tracing |
| `vouch-dirk-only.yaml` | Quick: 1 Vouch, 3 Dirk |
| `vouch-dirk-minimal.yaml` | Integration: 1 Vouch among Lighthouse VCs |

```bash
kurtosis run . --enclave vouch-dirk-devnet --image-download always \
  --args-file .github/tests/vouch-dirk-all-clients.yaml
```

## Monitor

```bash
kurtosis enclave inspect vouch-dirk-devnet          # ports/URLs
kurtosis service logs vouch-dirk-devnet <service>    # logs
curl -s http://127.0.0.1:<cl-port>/eth/v1/beacon/states/head/finality_checkpoints | jq
```

Vouch metrics (INFO logs are silent): `vouch_attestation_mark_seconds_count`, `vouch_beaconblockproposal_mark_seconds_count`, `vouch_synccommitteemessage_mark_seconds_count` at `http://127.0.0.1:<vouch-metrics-port>/metrics`.

## Teardown

```bash
kurtosis enclave rm -f vouch-dirk-devnet
```

## References

| Document | Read when... |
|----------|-------------|
| [architecture.md](references/architecture.md) | Creating configs, understanding participant fields, multi-cluster topology |
| [tracing.md](references/tracing.md) | Querying Tempo traces, debugging signing latency, using Grafana |
| [troubleshooting.md](references/troubleshooting.md) | Investigating finalization, common errors, Assertoor caveats |
