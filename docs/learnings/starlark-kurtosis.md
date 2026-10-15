# Starlark and Kurtosis

- Structs are immutable. Pass computed values, such as account ranges, as separate parameters instead of setting them on participant structs.
- Disable a fork with `18446744073709551615` (`FAR_FUTURE_EPOCH`). The input parser compares against that exact value, so any other large number counts as a scheduled fork.
- `kurtosis run --dry-run` checks images too and times out with an EOF error when an image needs pulling; pull first. It can also create an enclave, so record and remove it like any other.
