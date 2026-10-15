# Vouch and Dirk

## Config

- An active Vouch (`validator_count > 0`) creates a Dirk cluster and manages all of its accounts. A passive Vouch (`validator_count: 0`) joins one by `dirk_cluster_id` and serves the same accounts, so every instance sharing a cluster needs static-delay multi-instance. There are no partial account ranges: with the active instance owning its cluster, a range could only restate it.
- Vouch validators come from the Dirk DKG. `shared_utils.has_mnemonic_keys` excludes Vouch participants from the keystore generator, the genesis count and `validator-ranges.yaml`; use it wherever mnemonic key indices are counted.
- Vouch releases before 1.14 decode SSZ with mainnet sizes only. On the minimal preset every proposal fails to decode, so Vouch fixtures use the mainnet preset; 6s slots keep runs short.

## Tracing

- With `tempo` in `additional_services`, Vouch and Dirk trace to `tempo:4317`. The launchers strip `http://` from the Tempo URL because both expect a bare `host:port`.
- In Tempo mTLS mode only Vouch traces. Dirk and the CL clients get no Tempo URL, because they hold no client certificate.
- Query traces on Tempo's port 3200: `/api/search?tags=service.name%3DVouch`.

## Proving Dirk traffic

- The package runs Dirk at debug level, and Dirk logs client names only at trace. Prove that Vouch reached Dirk from Dirk's metrics: `dirk_checker_permissions{client="vouch-client"}` and `dirk_signer_process_requests_total`.
- Released Dirk (1.2.1, 1.3.0-rc.1) exports no `certmanager_*` gauges; Vouch 1.13.1 does. The certmanager test checks Vouch only until a Dirk release adds them.
