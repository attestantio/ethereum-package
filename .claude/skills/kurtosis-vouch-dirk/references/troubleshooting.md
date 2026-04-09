# Vouch/Dirk Devnet Troubleshooting

## Table of Contents
- [Devnet Verification Checklist](#devnet-verification-checklist)
- [Finalization Timing](#finalization-timing)
- [Querying Traces via Tempo](#querying-traces-via-tempo)
- [Common Vouch Errors](#common-vouch-errors)
- [Common Dirk Errors](#common-dirk-errors)
- [Assertoor Caveats](#assertoor-caveats)
- [CL Client Flag Differences](#cl-client-flag-differences)
- [YAML Template Pitfalls](#yaml-template-pitfalls)
- [Development Guide](#development-guide)

## Devnet Verification Checklist

Run these checks after deploying a devnet to confirm everything is healthy:

| # | Criterion | How to check | Expected |
|---|-----------|-------------|----------|
| 1 | Vouch starts | `kurtosis service logs vouch-dirk-devnet vouch-0-0 \| head -50` | "All services operational" |
| 2 | Dirk nodes healthy | `kurtosis service logs vouch-dirk-devnet dirk-a-1 2>&1 \| grep -i error` | 0 errors |
| 3 | Attestations flowing | `curl -s http://127.0.0.1:<vouch-metrics-port>/metrics \| grep vouch_attestation_mark_seconds_count` | Counter incrementing |
| 4 | Sync committee active | `curl -s http://127.0.0.1:<vouch-metrics-port>/metrics \| grep vouch_synccommitteemessage_mark_seconds_count` | Counter incrementing |
| 5 | No batch rejections | `kurtosis service logs vouch-dirk-devnet dirk-a-1 2>&1 \| grep "Multiple requests"` | No matches |
| 6 | Finalization (~26 min) | `curl -s http://127.0.0.1:<cl-port>/eth/v1/beacon/states/head/finality_checkpoints \| jq` | `finalized_epoch > 0` by epoch 5 |
| 7 | Passive Vouch inactive | Check metrics for passive instance | 0 attestations, 0 proposals |

**Timing**: checks 1-2 immediately after deploy, checks 3-5 after ~2 min, check 6 after ~26 min, check 7 anytime.

## Finalization Timing

The Casper FFG spec skips justification at the epoch 0-to-1 transition (`current_epoch <= GENESIS_EPOCH + 1`). The observed sequence:

| Epoch boundary | What happens |
|---|---|
| 0-to-1 (slot 32) | Early return, no justification |
| 1-to-2 (slot 64) | Runs, but epoch 1 NOT justified (genesis bootstrap) |
| 2-to-3 (slot 96) | Epoch 2 justified (first possible) |
| 3-to-4 (slot 128) | Epoch 3 justified, epochs 2+3 consecutive, **finalize epoch 2** |

**Earliest possible finalization = epoch 4 boundary = slot 128 = ~26 min at 12s slots.**

Do NOT treat delayed finalization before epoch 4 as a bug. If the chain hasn't finalized by **epoch 5 (~32 min)**, THEN investigate.

Check finalization:
```bash
curl -s http://127.0.0.1:<cl-http-port>/eth/v1/beacon/states/head/finality_checkpoints | jq
```

## Querying Traces via Tempo

When `tempo` is in `additional_services`, Vouch and Dirk automatically export OpenTelemetry traces to Tempo via OTLP/gRPC.

### Tempo API Endpoints

Get Tempo's port from `kurtosis enclave inspect`:
```bash
kurtosis enclave inspect vouch-dirk-devnet | grep tempo
```

Tempo exposes:
- **HTTP API** on port 3200 — for trace queries
- **OTLP gRPC** on port 4317 — for receiving traces (internal)
- **OTLP HTTP** on port 4318 — for receiving traces (internal)

### Search Traces by Service

```bash
# Vouch traces
curl -s "http://127.0.0.1:<tempo-http-port>/api/search?q=%7Bresource.service.name%3D%22Vouch%22%7D&limit=20" | jq

# Dirk traces
curl -s "http://127.0.0.1:<tempo-http-port>/api/search?q=%7Bresource.service.name%3D%22Dirk%22%7D&limit=20" | jq
```

### Get a Specific Trace

```bash
curl -s "http://127.0.0.1:<tempo-http-port>/api/traces/<trace-id>" | jq
```

### Search by Span Name

Useful span names in Vouch (110+ spans):
- `Proposal` — block proposal flow
- `Attest` — attestation flow
- `SyncCommitteeMessages` — sync committee signing
- Hierarchical names like `attestantio.vouch.strategies.beaconblockproposal.first`

Useful span names in Dirk:
- `Multisign` — distributed multi-signing
- `SignBeaconAttestations` — attestation signing
- `SignBeaconProposal` — proposal signing
- `SignGeneric` — generic signing
- `ListAccounts` — account listing

```bash
# Search for proposal spans
curl -s "http://127.0.0.1:<tempo-http-port>/api/search?q=%7Bname%3D%22Proposal%22%7D&limit=10" | jq

# Search for multisign spans
curl -s "http://127.0.0.1:<tempo-http-port>/api/search?q=%7Bname%3D%22Multisign%22%7D&limit=10" | jq
```

### View in Grafana

When both `prometheus_grafana` and `tempo` are enabled, Grafana is auto-configured with Tempo as a datasource. Open Grafana (port from `kurtosis enclave inspect`) and use the Explore tab with the Tempo datasource.

### Trace Latency Debugging

Use traces to diagnose slow signing. A Vouch attestation trace spans the full flow:
1. Vouch receives duty -> creates span
2. Calls Dirk `Multisign`/`SignBeaconAttestations` -> child span
3. Dirk runs rules check, threshold signing -> child spans
4. Response returned -> span ends

Slow spans indicate bottlenecks (network latency to Dirk, rules evaluation, threshold signing coordination).

## Common Vouch Errors

| Error | Meaning | Action |
|-------|---------|--------|
| "BLOCK_ERROR_ALREADY_KNOWN" | Normal — multinode submitter sends to all CLs, some already have the block via gossip | Ignore |
| "Not enough signatures: 0 signed, N denied" | Dirk denied all nodes — another Vouch instance already signed for this slot | Normal HA behavior when passive takes over |
| "Not enough components" | Dirk threshold signing failed — fewer than t nodes responded | Check Dirk node health |
| "Multiple requests for same key" | Dirk rejected batch with duplicate pubkeys | Fixed by batch splitting — rebuild vouch:local |
| "Failed to obtain beacon block header before timeout" | Multi-instance header strategy timed out — all CL nodes slow or block not yet propagated | Check if active Vouch has 0s delay (known timing issue); HA passive takes over |
| "Failed to obtain beacon block header; activating proposer" | Multi-instance fallback: header timeout triggered proposer activation | Expected when active instance can't see headers; proposals may still be denied by Dirk if passive already signed |
| "All services operational" then silence | Normal — Vouch at INFO doesn't log individual duties | Check Prometheus metrics |
| "job already exists" for sync committee aggregation | Scheduler race — two attempts to schedule the same job | Transient; sync committee signing still works |

## Common Dirk Errors

| Error | Meaning | Action |
|-------|---------|--------|
| "Denied by rules" + "Request target epoch equal to or lower than previous signed target epoch" | Slashing protection at epoch 0 — correct behavior, NOT a bug | Ignore at epoch 0 |
| "Denied by rules" + "Request slot equal to or lower than previous signed slot" | Another Vouch already signed a proposal for this slot | Normal HA behavior |
| "failed to obtain lock for account" | Two signing requests hit the same account simultaneously | Normal under high load |
| "pre-existing signature for slot" | Slashing protection triggered — already signed for this slot | Normal safety check |
| "unknown account" | DKG ceremony didn't populate the expected account | Check DKG logs, verify account ranges |

## Assertoor Caveats

- `stability-check` may fail with "context canceled" even when the chain is healthy and finalizing. This is an Assertoor timeout issue, not a stability problem.
- `block-proposal-check` is more reliable for confirming all client pairs proposed blocks.
- Always verify finalization directly via the CL API rather than relying solely on Assertoor.

## CL Client Flag Differences

The `--subscribe-all-subnets` flag syntax varies per client:

| Client | Flag |
|--------|------|
| Lighthouse | `--subscribe-all-subnets` |
| Lodestar | `--subscribe-all-subnets` |
| Nimbus | `--subscribe-all-subnets` |
| Prysm | `--subscribe-all-subnets=true` |
| Teku | `--p2p-subscribe-all-subnets-enabled=true` |

Always check `src/cl/<client>/<client>_launcher.star` for correct syntax.

## YAML Template Pitfalls

- The `vouch.star` template embeds YAML strings via `.format()`. Parameters `{2}` (dirk_endpoints) and `{4}` (accounts) MUST keep trailing `\n` because the next template line continues without a separator.
- Do NOT call `.rstrip("\n")` on `accounts_yaml` or `dirk_endpoints_yaml` — it breaks the YAML.
- `beacon_node_addresses_yaml` IS correctly `.rstrip("\n")`'d because the template has a literal `\n` after `{1}`.

## Development Guide

### Vouch/Dirk Test and Lint Commands

```bash
# Vouch
cd /Users/miguel-attestant/Documents/Projects/vouch
go test ./...                    # all tests
go test -race ./services/...     # race detection on services
golangci-lint run                # full lint suite

# Dirk
cd /Users/miguel-attestant/Documents/Projects/dirk
go test ./...                    # all tests
go test -race ./rules/standard/... # race detection on rules
golangci-lint run                # full lint suite
```

### Copyright Headers

Attestant repos use `goheader` linter. Copyright year ranges MUST use spaces around the dash:
```
// Copyright © 2020 - 2026 Attestant Limited.
```
NOT `2020-2026`. The linter regex expects ` - ` (space-dash-space).

### Kurtosis Lint

```bash
cd /Users/miguel-attestant/Documents/Projects/ethereum-package
kurtosis lint .              # check formatting
kurtosis lint . --format     # auto-fix
```

Runs `pyfound/black:23.9.1` via Docker. Requires Docker running.

### Rebuild Cycle

After code changes to Vouch or Dirk:
```bash
kurtosis enclave rm -f vouch-dirk-devnet          # tear down
docker build -t vouch:local .                      # rebuild in vouch/dirk dir
cd /Users/miguel-attestant/Documents/Projects/ethereum-package
kurtosis run . --enclave vouch-dirk-devnet --image-download always \
  --args-file .github/tests/vouch-dirk-all-clients.yaml
```
