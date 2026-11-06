# Vouch/Dirk five-pair

A Glamsterdam devnet-8 network that crosses into Gloas at epoch 2, with five different EL/CL pairs and Vouch on two Dirk clusters. It proves Vouch proposes Gloas blocks whose payloads the chain builds on, across every beacon node client, with natives holding 75% of the stake.

## Sub-features

- `five-pair-gloas`: the chain crosses Gloas at slot 64 and every Vouch Gloas proposal has its payload revealed.
- `five-pair-cluster-a`: one Vouch on Erigon/Lodestar with its own 2-of-3 Dirk cluster.
- `five-pair-cluster-b`: an active Vouch on Besu/Nimbus and a passive Vouch on a sixth Geth/Lighthouse pair, sharing a 2-of-3 Dirk cluster with static-delay.

## How to get to it (user POV)

- `kurtosis run . --args-file .github/tests/vouch-dirk-five-pair.yaml`
- The fixture is generated. Edit `.github/fixtures/layouts/vouch-dirk-five-pair.yaml`, then regenerate.

## Driving it with kurtosis

Preconditions: a fresh enclave name and about 12 GB of free Docker memory (six EL/CL pairs, six Dirk peers, three Vouch instances). If Docker goes above 85% memory, lower the validator counts and keep natives at 75% or more.

Ready when: the launch exits 0 and `doctor.sh` passes.

Health epoch: 5. Gloas starts at epoch 2, and the first full Gloas epoch (3) finalizes around epoch 5, the first epoch at which `devnet-health.sh` judges finality. Before it, `devnet-health.sh "$enclave" 5` exits 4: a smoke result.

Steps, between the common Launch/Doctor and Health/Proof steps in [README.md](README.md#common-steps):

- **Assertions.** `.github/tests/assert-vouch-dirk-five-pair.sh "$enclave" > "$run_dir/assert.txt" 2>&1`, from the start of epoch 3, once both clusters have proposed on Gloas; each cluster expects about 4 proposals per epoch. If a cluster has none yet, rerun it after the next epoch. Pass: exit 0 (512 genesis validators, head on Gloas, both clusters proposed Gloas blocks and every payload was revealed). Fail: any other exit.

## Gotchas

- Vouch 1.14.0-alpha.2 is the first release with Gloas support; it has no arm64 image.
- Lodestar rejects `prepareBeaconProposer` after Gloas with 410. Vouch 1.14.0-alpha.2 logs one "Failed to update proposal preparations" error per epoch; blocks still land.
- Envelope submissions fail with `BlockRootUnknown` on beacon nodes that have not seen the block yet. The multinode submitter reaches the others; this is a warning, not a failure.
- Proposals Vouch takes from a Lighthouse beacon node can carry Lighthouse's default graffiti.
- Erigon serves HTTP JSON-RPC on its `ws-rpc` port; the scripts handle it.
