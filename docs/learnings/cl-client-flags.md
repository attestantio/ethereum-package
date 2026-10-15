# CL client flags

Flag syntax differs per client. Before setting `cl_extra_params`, read `src/cl/<client>/<client>_launcher.star`, and run `git log --all -S "<flag>"` to find flags that were removed.

| Client | Subscribe to all subnets |
|--------|--------------------------|
| Lighthouse | `--subscribe-all-subnets` |
| Prysm | `--subscribe-all-subnets=true` |
| Teku | `--p2p-subscribe-all-subnets-enabled=true` |
| Lodestar | `--subscribe-all-subnets` |
| Nimbus | `--subscribe-all-subnets` |

Prysm boolean flags need an explicit `=true`. It ignores or rejects the bare form other clients accept.
