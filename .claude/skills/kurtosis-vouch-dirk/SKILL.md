---
name: kurtosis-vouch-dirk
description: Deploy and manage Vouch+Dirk Ethereum devnets using Kurtosis on the attestantio/ethereum-package fork. Use when spinning up local devnets with distributed validator technology (Vouch as validator client, Dirk as distributed threshold signer), testing Vouch/Dirk code changes, building local Docker images from fix branches, debugging devnet issues (finalization, attestation failures, sync committee errors), querying distributed traces via Tempo, or performing teardown/rebuild cycles after code changes. Covers multi-cluster Dirk architecture, multi-instance HA failover, account range partitioning, and devnet verification workflows.
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# Kurtosis Vouch/Dirk Devnet

Deploy Ethereum devnets with Vouch + Dirk via Kurtosis (`feat/add-vouch-dirk` branch).

## Build

Before building, ask the user which branches to use:
- **Vouch branch** (default: `master`)
- **Dirk branch** (default: `master`)

```bash
cd /Users/miguel-attestant/Documents/Projects/vouch
git checkout <vouch-branch>
docker build -t vouch:local .

cd /Users/miguel-attestant/Documents/Projects/dirk
git checkout <dirk-branch>
docker build -t dirk:local .
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

## Pitfalls

- **Tempo `grafana/tempo:latest` is broken** (v2.10+ requires Kafka). The default image is pinned to `grafana/tempo:2.7.2` in `input_parser.star`. Do NOT change to `:latest`.
- **Beacon node separation**: Different Vouch clusters should use different `vc_beacon_node_indices` to simulate realistic operator setups. Passive HA instances share the same indices as their active counterpart.
- **Static-delay `0s` for active instance**: The active Vouch in an HA pair MUST use `attester-delay: 0s` and `proposer-delay: 0s`. Vouch's staticdelay code (`service.go:79`) sets `attesterActive = (delay == 0)` — any non-zero value starts the instance passive, causing a deadlock where neither instance attests at genesis. The passive/standby instance should use `4s`/`2s`.
- **Finalization takes ~35 min on mainnet preset**: With 12s slots and 32 slots/epoch, finalization requires ~5 epochs of consistent attestation. Early epochs (0-2) have reduced participation as Vouch+Dirk stabilize. Use >= 128 validators per Vouch instance (256+ total) to ensure early-epoch justification clears the 2/3 Casper FFG threshold. Set finalization wait timeouts to at least 40 minutes.
- **Dirk "Denied by rules" at epoch 0** is expected — slashing protection correctly prevents re-signing at `targetEpoch=0`. This is NOT a bug.
- **Trace export errors** (`name resolver error: produced zero addresses`) mean Tempo DNS isn't resolving yet. These are transient during startup. If they persist, check `kurtosis service logs <enclave> tempo` for Tempo startup failures.
- **Do not use a native VC alongside Vouch**: Native VCs (e.g., Lighthouse VC) use keystore-generated keys which are separate from DKG-distributed keys. Their validators show "All validators inactive" because the deposits correspond to DKG keys, not keystore keys.

## Monitor

```bash
kurtosis enclave inspect vouch-dirk-devnet          # ports/URLs
kurtosis service logs vouch-dirk-devnet <service>    # logs
curl -s http://127.0.0.1:<cl-port>/eth/v1/beacon/states/head/finality_checkpoints | jq
```

Vouch at INFO does NOT log individual duty results (attestations, proposals, sync committee). After startup, silence is expected — "All services operational" then nothing. Verify signing via Prometheus counters at `http://127.0.0.1:<vouch-metrics-port>/metrics`:
- `vouch_attestation_mark_seconds_count` — attestations submitted
- `vouch_beaconblockproposal_mark_seconds_count` — proposals made
- `vouch_synccommitteemessage_mark_seconds_count` — sync committee messages

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
