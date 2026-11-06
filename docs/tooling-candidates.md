# Tooling candidates

Invariants a tool could enforce. Each row names the invariant, how a violation shows up and how to enforce it.

## Not yet automated

| Invariant | Violation symptom | Enforcement idea |
|-----------|-------------------|------------------|
| Optional integer fields in `input_parser.star` use `None` as the unset value, never `-1` | Silent misparse or `-1` reaching downstream logic | Semgrep rule matching `-1` assigned to optional fields in `input_parser.star` |
| A shell check that must fail the script is an explicit `if …; then exit 1; fi`, never `! cmd` | `set -e` ignores a failing `! cmd`, so the check never fails | shellcheck SC2251 over `.github/tests/*.sh` and the skill scripts in CI |
| `STRATEGY_NAMES` in `src/vc/vouch_strategies.star` matches the `strategies.*` keys Vouch reads | A new Vouch strategy is rejected at parse time, or a removed one still passes | Script that extracts the `strategies.*` keys Vouch reads at a pinned tag and diffs the names |
| `VOUCH_FIELDS` in `input_parser.star`, `PARTICIPANT_CATEGORIES` in `sanity_check.star` and `default_participant()` list the same Vouch fields | A new field is accepted by one check and rejected by another | Unit test that compares the three lists |

## Already enforced

| Invariant | Tool |
|-----------|------|
| No implicit string concatenation in Starlark (`"foo" "bar"`) | Starlark parser, `kurtosis lint` |
| Nimbus needs 12s slots on the mainnet preset and 6s on minimal | `input_parser.star` |
| Generated fixtures match their layouts | `generate-fixture.py --check` in the fixture-tooling workflow |
