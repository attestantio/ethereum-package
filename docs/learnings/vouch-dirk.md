# Vouch and Dirk

## Config

- Every Vouch instance sharing a Dirk cluster needs static-delay multi-instance. There are no partial account ranges: with the active instance owning its cluster, a range could only restate it.
- Vouch validators come from the Dirk DKG. `shared_utils.has_mnemonic_keys` excludes Vouch participants from the keystore generator, the genesis count and `validator-ranges.yaml`; use it wherever mnemonic key indices are counted.

## Strategies

- Vouch ignores unknown `strategies.*` sections, so a misspelled name changes nothing and logs nothing. An unknown `style` falls back to `simple` without a warning. The package checks strategy names and value shapes only.
- Vouch never read `strategies.duties`. The package no longer renders it.
- A bare number for a duration (`timeout: 1800`) is read as nanoseconds, 1.8µs. The package requires a unit (`1800ms`).
- `style: combinedmajority` reads only `combinedmajority.threshold`, not `majority.threshold` (attestantio/vouch#463). Without it Vouch applies no minimum, so the package requires it. Remove that check once every Vouch image the package targets has the fallback from attestantio/vouch#474.

## Tracing

- With `tempo` in `additional_services`, Vouch and Dirk trace to `tempo:4317`. The launchers strip `http://` from the Tempo URL because both expect a bare `host:port`.
- In Tempo mTLS mode only Vouch traces. Dirk and the CL clients get no Tempo URL, because they hold no client certificate.
- Query traces on Tempo's port 3200: `/api/search?tags=service.name%3DVouch`.

## Proving Dirk traffic

- The package runs Dirk at debug level, and Dirk logs client names only at trace. Prove that Vouch reached Dirk from Dirk's metrics: `dirk_checker_permissions{client="vouch-client"}` and `dirk_signer_process_requests_total`.
- Released Dirk (1.2.1, 1.3.0-rc.1) exports no `certmanager_*` gauges; Vouch 1.13.1 does. The certmanager test checks Vouch only until a Dirk release adds them.
