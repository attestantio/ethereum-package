# Vouch/Dirk five-pair

A Glamsterdam devnet-8 network that crosses into Gloas at epoch 2, with five EL/CL pairs that hold validators, a sixth pair for a passive Vouch, and Vouch on two 2-of-3 Dirk clusters. Natives hold 75% of the stake. It proves that each cluster's Vouch proposes Gloas blocks whose payloads the chain builds on, and that Vouch and Dirk run the settings the layout gives them.

## Sub-features

- `five-pair-gloas`: the chain crosses Gloas at slot 64 and every Vouch Gloas proposal has its payload built on by the next block.
- `five-pair-cluster-a`: one Vouch on Erigon/Lodestar with its own 2-of-3 Dirk cluster. It uses beacon nodes 1 to 5 and the cluster's Dirk peers, manages all of the cluster's DKG accounts and attests.
- `five-pair-cluster-b`: an active Vouch on Besu/Nimbus and a passive Vouch on a sixth Geth/Lighthouse pair share a 2-of-3 Dirk cluster under static-delay: 250ms and 500ms on the active, 4s and 2s on the passive. Both use beacon nodes 1 to 5 and manage the cluster's accounts, and the passive attests less than the active.
- `five-pair-dirk`: each cluster's Dirk peers signed at least twice what its Vouch instances report, because a signature needs two of three peers.

## How to get to it (user POV)

- `kurtosis run . --args-file .github/tests/vouch-dirk-five-pair.yaml`
- The fixture is generated. Edit `.github/fixtures/layouts/vouch-dirk-five-pair.yaml`, then regenerate.

## Driving it with kurtosis

Preconditions: a fresh enclave name and about 15 GB of free Docker memory (six EL/CL pairs, six Dirk peers, three Vouch instances; the enclave used 8.5 to 14.2 GiB in two runs).

Ready when: the launch exits 0 and `doctor.sh` passes.

Health epoch: 5, the first epoch at which `devnet-health.sh` judges finality. Gloas starts at epoch 2.

Steps, between the common Launch/Doctor and Health/Proof steps in [README.md](README.md#common-steps):

- **Assertions.** `.github/tests/assert-vouch-dirk-five-pair.sh "$enclave" > "$run_dir/assert.txt" 2>&1; echo $? > "$run_dir/assert.exit"`, from the start of epoch 3, when each cluster has about 4 Gloas proposals. The last line is `RESULT: PASS`, `FAIL`, `BLOCKED` or `ERROR`; the exit code follows it:
  - 0, pass: both clusters' DKG validators are in genesis, each Vouch uses its beacon nodes, Dirk peers and delays, each cluster's Gloas proposals have their payloads built on, each Vouch manages its cluster's accounts, the passive attests less than the active, and Dirk signed at least twice what Vouch reports.
  - 1, fail: a `FAIL` line names the check, and a payload failure names its slot and cluster. It is a finding: read that slot in the cluster's Vouch log and in the log of the beacon node that proposes the next slot (see Gotchas). An unbuilt payload stays in every later run's window, so a rerun on the same enclave cannot clear it; test a fix on a fresh enclave.
  - 4, blocked and nothing failed: the head is not on Gloas yet, or a cluster has no Gloas proposal yet, so the metrics were not read. Rerun after the next epoch. From epoch 5 it counts as a failure: a cluster with 1/8 of the validators has no proposal in 96 slots about 3 times in a million.
  - 2, could not run: a service, port or answer could not be read. Fix the access and rerun on the same enclave.

## Gotchas

- Vouch 1.14.0-alpha.2 is a Gloas build: alpha.1 added Gloas proposals, and stable 1.13.x has none. Neither it nor Dirk has an arm64 image; follow the amd64-only step in the README.
- Natives hold 75% of the stake, so the chain finalizes without Vouch. `devnet-health.sh` and finality prove nothing about Vouch here; the assertions do.
- The passive Vouch activates for a proposal when it sees no block in time, and then Dirk's slashing protection decides which instance signs. Each peer signs the first request for a slot and denies the second, so the passive's duplicate gets `0 signed, 3 denied` or `1 signed, 2 denied`, and it can win a slot when its requests reach two peers first. The assertions print Dirk's denied proposals and compare nothing about them or about who proposed.
- `BlockRootUnknown` on an envelope submission is benign only while the next block still builds on the payload; the assertions judge that, not the log. Vouch posts a self-built block and then its envelope about 50 ms later, and a beacon node that has not finished importing the block refuses the envelope. In one run Prysm refused 9 of 27 envelopes without harm. Lighthouse v8.3.1 refused one, its own validator proposed the next slot, and the payload check failed: its log says `Prepared beacon proposer ... payload_status: Empty` and the next bid's `parent_block_hash` is the earlier block's. That is the only lost payload in the 333 cluster proposals of three runs, so expect an occasional failing run. It fits sigp/lighthouse#10519, where an envelope deferred during block import waits a full slot. Report it as client compatibility.
- Lodestar's 410 on proposal preparations, `BlockRootUnknown` and Lighthouse's default graffiti are expected noise (`docs/learnings/devnet-operations.md`, Vouch signing).
- Erigon serves HTTP JSON-RPC on its `ws-rpc` port; the scripts handle it.
- Keep the host awake for the whole run and judge only an enclave that never paused (`docs/learnings/devnet-operations.md`, Host sleep).
