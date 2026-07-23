# Multi-Cluster Dirk Architecture

## Vouch/Dirk Participant Fields

Fields for `participants[]` entries with `vc_type: vouch`:

```yaml
# Required for all Vouch participants
vc_type: vouch
vc_image: vouch:local
use_separate_vc: true
validator_count: 64            # 0 for passive HA standby

# Required for the FIRST participant in a Dirk cluster (creates the cluster)
dirk_peer_count: 5             # Dirk nodes in this cluster
dirk_signing_threshold: 3      # t-of-n threshold
dirk_cluster_id: a             # Single lowercase letter [a-z0-9]
dirk_image: dirk:local

# Required for JOINING an existing cluster (passive/second Vouch)
dirk_cluster_id: a             # Same cluster ID, no dirk_peer_count

# Multi-instance HA (active/passive pairs sharing accounts)
vouch_multiinstance_style: 'static-delay'
vouch_multiinstance_attester_delay: '1s'   # 1s=active, 4s=passive
vouch_multiinstance_proposer_delay: '1s'   # 1s=active, 2s=passive

# Explicit account ranges (for passive Vouch or split validators)
vouch_account_start: 0
vouch_account_count: 64

# Recommended: which CL nodes this Vouch queries
vc_beacon_node_indices: [0, 1, 2, 3, 4, 5, 6]
```

## Cluster Topology

Each `dirk_cluster_id` creates an independent Dirk cluster with its own DKG ceremony.

Service naming: `dirk-{cluster_id}-{n}` (e.g. `dirk-a-1`, `dirk-b-3`).

Example topology (from `vouch-dirk-all-clients.yaml`):

```
Cluster A (dirk_cluster_id: a)
  5 Dirk nodes (3/5 threshold)
  Vouch 1 — active,  accounts 0-63
  Vouch 2 — passive, accounts 0-63 (1s attester delay, 2s proposer delay)

Cluster B (dirk_cluster_id: b)
  5 Dirk nodes (3/5 threshold)
  Vouch 3 — independent, accounts 64-127
```

## Key Rules

- First participant with a `dirk_cluster_id` must set `dirk_peer_count` + `dirk_signing_threshold` (creates the cluster)
- Subsequent participants with the same `dirk_cluster_id` join without creating new Dirk nodes
- Passive Vouch (`validator_count: 0`) needs explicit `vouch_account_start`/`vouch_account_count`
- CL `--subscribe-all-subnets` syntax varies per client — check `src/cl/<client>/<client>_launcher.star`
- Include at least one `supernode: true` participant for Fulu PeerDAS data availability
- Non-Vouch participants with `validator_count: 0` serve as CL diversity peers

## Beacon Node Separation

Different Vouch clusters should use different `vc_beacon_node_indices` to simulate realistic operator setups:

```yaml
# Cluster A (active + passive share the same CL nodes)
vc_beacon_node_indices: [0, 1, 3, 4]   # Lighthouse, Teku, Lodestar, Nimbus

# Cluster B (independent CL nodes)
vc_beacon_node_indices: [2, 5, 6]       # Prysm, Teku, Lighthouse
```

Rules:
- Active and passive Vouch instances in the same cluster MUST share the same beacon node indices
- Different clusters SHOULD use different subsets for realistic separation
- Ensure each subset has client diversity (mix of CL implementations)
- Include enough nodes for the "first" strategy to have redundancy (3+ recommended)

## Custom Config Tips

- Start from an existing `.github/tests/vouch-dirk-*.yaml` and modify
- Use `seconds_per_slot: 12` if nimbus is included (cannot run below 12 on mainnet preset)
- Use `FAR_FUTURE_EPOCH` (`18446744073709551615`) to disable forks, not arbitrary large numbers
- `kurtosis run . --dry-run` validates syntax and config but may timeout pulling images — pre-pull first
- Only include config fields that differ from defaults — shorter configs are better (borrowed from kurtosis-ethereum skill)
