# AGENTS.md

Attestant's fork of `ethpandaops/ethereum-package`: a Kurtosis package that launches Ethereum devnets, plus Vouch and Dirk support and the fixtures that prove it. Keep package changes ready to send upstream; Attestant-only tooling lives under `.agents/`, `.github/fixtures/` and `docs/`.

## Commands

- Lint: `kurtosis lint .`
- Launch: `kurtosis run . --enclave <name> --args-file <fixture>.yaml`
- Fixture tooling tests: `python3 -m unittest discover -s .github/fixtures` (needs PyYAML)
- Regenerate fixtures from their layouts: `python3 .github/fixtures/generate-fixture.py`; CI runs it with `--check`.

## Where to look

- **Verifying** a fixture, a package change or a devnet layout on a live enclave: load the `verify-ethereum-package` skill. It owns enclave ownership, evidence and cleanup rules.
- **Launch mechanics** (config fields, `kurtosis` commands, client images): the `kurtosis-ethereum` skill.
- **Learnings** by area, read before working in that area: [docs/learnings/README.md](docs/learnings/README.md).
- **Tooling candidates**, invariants that could become checks: [docs/tooling-candidates.md](docs/tooling-candidates.md). Add a row when a review catches something a tool could catch.

## Divergences from upstream

Check this list after every sync with upstream `main`, and drop an entry once its removal condition holds.

- `.github/check-consensus-spec-values.py` excludes `EIP8198_FORK_EPOCH`, `EIP8198_FORK_VERSION` and `SLOT_DURATION_MS_EIP8198`. The genesis generator emits `SLOT_DURATION_MS_HEZE` in their place (upstream ethpandaops/ethereum-package#1499), so upstream's own spec check fails. We chose green CI with a documented gap over a red check we cannot fix here. Remove the exclusions once the generated config carries those fields or the spec drops them.
