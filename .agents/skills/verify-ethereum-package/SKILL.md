---
name: verify-ethereum-package
description: Prove that an ethereum-package fixture or devnet layout launches and behaves as claimed, by running it as a Kurtosis enclave and capturing setup records, health and fixture assertions. Use after changing package code or a fixture, when asked to validate a change on a Kurtosis devnet, or when another verification skill (such as a client's verify skill) needs a proven network.
---

# Verify ethereum-package

The package's user surface is a YAML args file passed to `kurtosis run`, the enclave it creates, and the networks' APIs. Verification means launching a fixture from this checkout, proving the deployed setup matches the args file, proving the chain is healthy on every client, and running the fixture's own assertions.

Launch mechanics (config fields, `kurtosis` commands, images) are in the upstream `kurtosis-ethereum` skill in this repo (`.agents/skills/kurtosis-ethereum`). This skill adds ownership, readiness, proof and evidence. Pick the fixture from [`fixtures/README.md`](fixtures/README.md) first; every check maps to a recipe there.

Scripts below are relative to `.agents/skills/verify-ethereum-package/scripts/` and run from the repo root. They need bash 4.3 or newer, `git`, `jq`, `curl`, `shasum`, `docker` and `kurtosis`; `review-page.sh` also needs `uv`.

## Launch

1. **Run directory.** Pick a run name `<fixture>-<yyyymmdd><letter>` and set `run_dir="${VERIFY_EVIDENCE_DIR:-$HOME/ValidationReviews}/$run"`. Evidence lives there, outside every repo.
2. **Inventory.** Save `kurtosis enclave ls` to `$run_dir/enclaves-before.txt`. Every enclave listed there belongs to someone else. The enclave name for this run must not appear in it.
3. **Setup before.** Run `setup-before.sh <args-file> "$run_dir"`, then replace its Topology placeholder with the participants, client per role, validator split and any Vouch/Dirk layout. Put any edited args file in `$run_dir` and launch that copy. On Apple Silicon, apply the arm64 image override from [`fixtures/README.md`](fixtures/README.md) this way.
4. **Run.** `kurtosis run . --enclave "$enclave" --args-file <args-file> > "$run_dir/launch.log" 2>&1`. Record the full UUID from `kurtosis enclave inspect --full-uuids "$enclave"` in `$run_dir/resources.md` straight away, even if the run failed part-way. A failed `inspect` does not prove the enclave is absent.
5. **Ready.** The fixture file's `Ready when:` line holds. Ready means usable: running containers or a sync flag are not enough.

`launch.log` contains the network's prefunded private keys. Keep it in the run directory and redact it before sharing. `kurtosis run --dry-run` can still create an enclave; record and clean it like any other.

## Doctor

```bash
.agents/skills/verify-ethereum-package/scripts/doctor.sh "$enclave"
```

Read-only. Checks the enclave is running, every `el-`, `cl-`, `vc-` and `dirk-` container and `tempo` is running, and every beacon node's head is within 2 slots of the wall clock. Exit 0 means worth driving. Run it first, and again whenever something looks off.

For chain health beyond the head, run `devnet-health.sh "$enclave"`. It checks peers, head progress against the wall clock, block-root agreement across every client, justification and finality, missed slots and EL heights. Exit 0 is healthy, 1 is no healthy majority chain, 3 is a client off the chain, stalled or not finalizing while the majority is healthy, and 2 means the check could not run. A healthy majority does not verify a diverged client: record each one.

## Drive

Each fixture file names its assertions. Most are `.github/tests/assert-<fixture>.sh "$enclave"`. Resolve every endpoint from the live enclave:

```bash
beacon="$(kurtosis port print "$enclave" cl-1-<cl>-<el> http)"
kurtosis service logs -a "$enclave" <service> --match '<text>'
```

Use `kurtosis port print` for ports; the inspect table's metrics column also holds `http://` URLs and parses to the wrong port.

## Evidence

Everything goes in `$run_dir`: `SETUP-before.md`, `launch.log`, assertion and health output, `SETUP-after.md` and `REPORT.md`.

- **Setup after.** Before cleanup, run `setup-after.sh "$enclave" "$run_dir"`, then fill its Differences section by comparing it with `SETUP-before.md`.
- **Report.** `REPORT.md` lists each criterion with pass, fail or blocked, and the file that proves it. A criterion whose precondition never happened is blocked; never substitute a weaker check.
- **Failures.** Save logs, configs and chain state before changing anything. Classify each failure as infrastructure, client compatibility, test error or package regression, and say which in the report.
- **Review page.** Run `review-page.sh "$run_dir"` after any change to the three Markdown files. It builds and opens `$run_dir/index.html`, which shows them together with the sign-off status from `$run_dir/signoff.md`. Point reviewers at that page.

## Cleanup

Remove only what this run created, by the full UUID in `resources.md`: `kurtosis enclave rm -f <full-uuid>`. Never use `kurtosis clean`, Docker prune or name-prefix deletion; they reach enclaves other runs own. Mark removed IDs in `resources.md`. The run directory stays.

## Helpers

Every script prints its usage and exits 2 on wrong arguments or an unknown enclave. `lib.sh` holds shared service discovery and is sourced, not run.
