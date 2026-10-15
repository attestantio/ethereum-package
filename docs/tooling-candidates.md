# Tooling candidates

Invariants a tool could enforce. Each row names the invariant, how a violation shows up and how to enforce it.

## Not yet automated

| Invariant | Violation symptom | Enforcement idea |
|-----------|-------------------|------------------|
| Optional integer fields in `input_parser.star` use `None` as the unset value, never `-1` | Silent misparse or `-1` reaching downstream logic | Semgrep rule matching `-1` assigned to optional fields in `input_parser.star` |

## Already enforced

| Invariant | Tool |
|-----------|------|
| No implicit string concatenation in Starlark (`"foo" "bar"`) | Starlark parser, `kurtosis lint` |
| Nimbus needs 12s slots on the mainnet preset and 6s on minimal | `input_parser.star` |
| Generated fixtures match their layouts | `generate-fixture.py --check` in per-PR CI |
