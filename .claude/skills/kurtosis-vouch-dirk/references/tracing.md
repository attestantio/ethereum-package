# Distributed Tracing with Tempo

Both Vouch (OTel v1.40, 110+ spans) and Dirk (OTel v1.30, gRPC auto-instrumentation) export traces via OTLP/gRPC. When `tempo` is in `additional_services`, traces are automatically sent to Tempo.

The `vouch-dirk-all-clients.yaml` config includes Tempo by default.

## Tempo Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 3200 | HTTP | Tempo query API |
| 4317 | gRPC | OTLP trace receiver (internal) |
| 4318 | HTTP | OTLP trace receiver (internal) |

Get the mapped port: `kurtosis enclave inspect vouch-dirk-devnet | grep tempo`

## Query Traces

```bash
# Search Vouch traces
curl -s "http://127.0.0.1:<tempo-http-port>/api/search?q={resource.service.name=\"Vouch\"}&limit=20" | jq

# Search Dirk traces
curl -s "http://127.0.0.1:<tempo-http-port>/api/search?q={resource.service.name=\"Dirk\"}&limit=20" | jq

# Get a specific trace by ID
curl -s "http://127.0.0.1:<tempo-http-port>/api/traces/<trace-id>" | jq

# Search by span name
curl -s "http://127.0.0.1:<tempo-http-port>/api/search?q={name=\"Multisign\"}&limit=10" | jq
```

## Key Span Names

### Vouch
- `Proposal` — block proposal flow
- `Attest` — attestation flow
- `SyncCommitteeMessages` — sync committee signing
- Hierarchical: `attestantio.vouch.strategies.beaconblockproposal.first`, etc.

### Dirk
- `Multisign` — distributed multi-signing (the hot path)
- `SignBeaconAttestations` — attestation signing
- `SignBeaconProposal` — proposal signing
- `SignGeneric` — generic signing
- `ListAccounts` — account listing

## Grafana Integration

When both `prometheus_grafana` and `tempo` are enabled, Grafana auto-configures Tempo as a datasource. Use the **Explore** tab with the Tempo datasource to query traces visually.

## Trace Latency Debugging

A typical attestation trace spans:
1. Vouch receives duty -> creates span
2. Vouch calls Dirk `Multisign`/`SignBeaconAttestations` -> child span
3. Dirk runs rules check, threshold signing -> child spans
4. Response returned -> span ends

Slow spans indicate bottlenecks: network latency to Dirk, rules evaluation, or threshold signing coordination.
