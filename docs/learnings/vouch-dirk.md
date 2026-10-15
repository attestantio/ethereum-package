# Vouch and Dirk

## Config

- An active Vouch (`validator_count > 0`) creates a Dirk cluster and manages all of its accounts. A passive Vouch (`validator_count: 0`) joins a cluster and needs `vouch_account_start` and `vouch_account_count`; only passive instances may set them.
- Vouch validators come from the Dirk DKG. The keystore generator and the genesis count both skip Vouch participants, so their mnemonic keys never exist.
- Vouch releases before 1.14 decode SSZ with mainnet sizes only. On the minimal preset every proposal fails to decode, so Vouch fixtures use the mainnet preset with 6s slots.

## Tracing

- With `tempo` in `additional_services`, Vouch and Dirk trace to `tempo:4317`. The launchers strip `http://` from the Tempo URL because both expect a bare `host:port`.
- In Tempo mTLS mode only Vouch traces; Dirk tracing is off.
- Query traces on Tempo's port 3200: `/api/search?tags=service.name%3DVouch`.

## Proving Dirk traffic

- The package runs Dirk at debug level, and Dirk logs client names only at trace. Prove that Vouch reached Dirk from Dirk's metrics: `dirk_checker_permissions{client="vouch-client"}` and `dirk_signer_process_requests_total`.
- Released Dirk (1.2.1, 1.3.0-rc.1) exports no `certmanager_*` gauges; Vouch 1.13.1 does. The certmanager test checks Vouch only until a Dirk release adds them.
