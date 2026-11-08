# Tooling candidates

Invariants a tool could enforce. Each row names the invariant, how a violation shows up and how to enforce it.

## Not yet automated

| Invariant | Violation symptom | Enforcement idea |
|-----------|-------------------|------------------|
| Optional integer fields in `input_parser.star` use `None` as the unset value, never `-1` | Silent misparse or `-1` reaching downstream logic | Semgrep rule matching `-1` assigned to optional fields in `input_parser.star` |
| A shell check that must fail the script is an explicit `if …; then exit 1; fi`, never `! cmd` | `set -e` ignores a failing `! cmd`, so the check never fails | shellcheck SC2251 over `.github/tests/*.sh` and the skill scripts in CI |
| `STRATEGY_NAMES` in `src/vc/vouch_strategies.star` matches the `strategies.*` keys Vouch reads | A new Vouch strategy is rejected at parse time, or a removed one still passes | Script that extracts the `strategies.*` keys Vouch reads at a pinned tag and diffs the names |
| `VOUCH_FIELDS` in `input_parser.star`, `PARTICIPANT_CATEGORIES` in `sanity_check.star` and `default_participant()` list the same Vouch fields | A new field is accepted by one check and rejected by another | Unit test that compares the three lists |
| Files follow the indentation `.editorconfig` declares (4 spaces for Python) | Reviews argue about style, and a new `.py` file matches neither the rule nor its neighbours | editorconfig-checker in CI |
| The host ports an args file publishes are free when the run launches | The launch fails after about a minute with `port is already allocated` because another enclave publishes the same range | Check in `setup-before.sh` that compares the args file's `port_publisher` ranges with `docker ps` ports |
| An assertion script fails closed: an absent field or a failed request is a failure or an error, never a pass | A script compares two empty fields as equal, or reads a failed `curl` as an empty slot, and a broken chain passes | Lint `|| continue` and `|| true` after `curl` and `jq` in `.github/tests/assert-*.sh`, and a stub-server test per script that serves empty fields and HTTP errors |

## Already enforced

| Invariant | Tool |
|-----------|------|
| No implicit string concatenation in Starlark (`"foo" "bar"`) | Starlark parser, `kurtosis lint` |
| Nimbus needs 12s slots on the mainnet preset and 6s on minimal | `input_parser.star` |
| Generated fixtures match their layouts, and every generated fixture has a layout | `generate-fixture.py --check` in the fixture-tooling workflow |
| A generated fixture parses back to its layout plus `network_params` | `generate-fixture.py`, on every generation |
| `sed` lines in the skill scripts avoid `\s`, `\S`, `\d` and `\w`, which BSD sed on macOS lacks (the Images table came out as raw `grep -n` lines) | `test_skill_scripts.py` |
| No script or recipe runs `eval "$(cmd)"` without first checking that `cmd` succeeded (a failed `cmd` prints nothing, `eval` returns 0, and a later step writes a blank value) | `test_skill_scripts.py` |
| Exit codes of `devnet-health.sh` and the records `setup-before.sh` and `setup-after.sh` write, including their failure paths | `test_skill_scripts.py`, against a stub `kurtosis`, `docker` and local beacon and EL servers |
| `assert-vouch-dirk-five-pair.sh` passes, fails, blocks or errors as its header says: an absent bid field, an HTTP error, a missing metric and a wrong Vouch or Dirk setting do not pass | `test_assert_five_pair.py`, against a stub `kurtosis` and local beacon and metrics servers |
