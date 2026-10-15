#!/usr/bin/env python3
"""Generate a test fixture's network_params from a pinned source.

A layout in .github/fixtures/layouts/<name>.yaml holds a fixture without
network_params, plus a top-level `fixture_source` block:

  fixture_source:
    mode: next-fork            # or: mainnet
    repo: ethpandaops/glamsterdam-devnets
    commit: <full sha>
    devnet: devnet-8
    network_params:            # optional local overrides, applied last
      seconds_per_slot: 6

The generator writes .github/tests/<name>.yaml: a header naming the source,
the layout without `fixture_source`, then the generated network_params.
`--check` regenerates every layout and fails if a fixture differs.
"""

import argparse
import difflib
import json
import pathlib
import re
import sys
import urllib.request

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
LAYOUTS = ROOT / ".github/fixtures/layouts"
TESTS = ROOT / ".github/tests"

FAR_FUTURE = 18446744073709551615
# Epoch the devnet's next fork moves to, so every run crosses its boundary.
NEXT_FORK_EPOCH = 2
GENESIS_DELAY = 20
SLOTS_PER_EPOCH = {"mainnet": 32, "minimal": 8}
FORKS = ["altair", "bellatrix", "capella", "deneb", "electra", "fulu", "gloas", "heze"]
MAINNET_LIVE_FORKS = ["altair", "bellatrix", "capella", "deneb", "electra", "fulu"]
BPO_SLOTS = 5
PEERDAS_KEYS = [
    "data_column_sidecar_subnet_count",
    "samples_per_slot",
    "custody_requirement",
    "validator_custody_requirement",
    "min_epochs_for_data_column_sidecars_requests",
]


def fetch(url):
    with urllib.request.urlopen(url, timeout=30) as response:
        return response.read().decode()


def fetch_devnet(source):
    base = f"https://raw.githubusercontent.com/{source['repo']}/{source['commit']}/network-configs/{source['devnet']}/metadata"
    # Upstream config.yaml has unquoted hex values; load them as strings.
    config = yaml.load(fetch(base + "/config.yaml"), Loader=yaml.BaseLoader)
    genesis = json.loads(fetch(base + "/genesis.json"))
    return config, genesis


def rebase(epoch, next_fork):
    """Move an epoch so the next fork lands on NEXT_FORK_EPOCH, keeping offsets."""
    if epoch == 0 or epoch == FAR_FUTURE:
        return epoch
    return max(0, epoch - next_fork + NEXT_FORK_EPOCH)


def next_fork_params(config, genesis):
    epochs = {fork: int(config[f"{fork.upper()}_FORK_EPOCH"]) for fork in FORKS}
    scheduled = [e for e in epochs.values() if e not in (0, FAR_FUTURE)]
    if not scheduled:
        sys.exit("source schedules no fork after genesis")
    next_fork = min(scheduled)
    slot_ms = int(config["SLOT_DURATION_MS"])
    epoch_ms = slot_ms * SLOTS_PER_EPOCH[config["PRESET_BASE"]]
    genesis_time = int(genesis["timestamp"], 0) if isinstance(genesis["timestamp"], str) else genesis["timestamp"]

    params = {
        "network": "kurtosis",
        "preset": config["PRESET_BASE"],
        "network_id": str(config["DEPOSIT_CHAIN_ID"]),
        "deposit_contract_address": config["DEPOSIT_CONTRACT_ADDRESS"],
        "slot_duration_ms": slot_ms,
        "genesis_delay": GENESIS_DELAY,
        "genesis_gaslimit": int(genesis["gasLimit"], 16),
        "genesis_fork_version": config["GENESIS_FORK_VERSION"],
    }
    # seconds_per_slot only holds whole seconds; the package derives it otherwise.
    if slot_ms % 1000 == 0:
        params["seconds_per_slot"] = slot_ms // 1000
    if "MIN_BUILDER_WITHDRAWABILITY_DELAY" in config:
        params["min_builder_withdrawability_delay"] = int(config["MIN_BUILDER_WITHDRAWABILITY_DELAY"])
    for fork in FORKS:
        params[f"{fork}_fork_epoch"] = rebase(epochs[fork], next_fork)
        params[f"{fork}_fork_version"] = config[f"{fork.upper()}_FORK_VERSION"]

    # The EL genesis lists every blob step with its target and fraction. The CL
    # config's BLOB_SCHEDULE collapses steps that share an epoch, so it is not used.
    schedule = genesis["config"]["blobSchedule"]
    # cancun predates Electra and keeps the package default.
    known = {"cancun", "prague"} | {f"bpo{n}" for n in range(1, BPO_SLOTS + 1)}
    unknown = sorted(set(schedule) - known)
    if unknown:
        sys.exit(f"blobSchedule has steps the generator does not map: {', '.join(unknown)}")
    prague = schedule["prague"]
    params["max_blobs_per_block_electra"] = prague["max"]
    params["target_blobs_per_block_electra"] = prague["target"]
    params["base_fee_update_fraction_electra"] = prague["baseFeeUpdateFraction"]
    for n in range(1, BPO_SLOTS + 1):
        step = schedule.get(f"bpo{n}")
        if step is None:
            params[f"bpo_{n}_epoch"] = FAR_FUTURE
            continue
        activation = genesis["config"][f"bpo{n}Time"]
        epoch = 0 if activation <= genesis_time else (activation - genesis_time) * 1000 // epoch_ms
        params[f"bpo_{n}_epoch"] = rebase(epoch, next_fork)
        params[f"bpo_{n}_max_blobs"] = step["max"]
        params[f"bpo_{n}_target_blobs"] = step["target"]
        params[f"bpo_{n}_base_fee_update_fraction"] = step["baseFeeUpdateFraction"]

    gas = config.get("GAS_LIMIT_SCHEDULE", [])
    if gas:
        params["gas_limit_schedule"] = [
            {"epoch": rebase(int(e["EPOCH"]), next_fork), "gas_limit": int(e["GAS_LIMIT"])} for e in gas
        ]
    for key in PEERDAS_KEYS:
        params[key] = int(config[key.upper()])
    return params


def mainnet_params():
    # Written out, though they equal today's defaults, so the fixture keeps them
    # if the package defaults move to a newer fork.
    params = {"network": "kurtosis", "preset": "mainnet"}
    for fork in FORKS:
        params[f"{fork}_fork_epoch"] = 0 if fork in MAINNET_LIVE_FORKS else FAR_FUTURE
    return params


def apply_overrides(params, overrides):
    """Apply layout overrides, keeping the two slot-length fields consistent."""
    params.update(overrides)
    if "seconds_per_slot" in overrides and "slot_duration_ms" not in overrides and "slot_duration_ms" in params:
        params["slot_duration_ms"] = overrides["seconds_per_slot"] * 1000
    if "slot_duration_ms" in overrides and "seconds_per_slot" not in overrides and "seconds_per_slot" in params:
        params["seconds_per_slot"] = overrides["slot_duration_ms"] // 1000
    return params


def strip_source(text):
    """Remove the top-level fixture_source block (its indented and blank lines)."""
    return re.sub(r"(?m)^fixture_source:\n(?:[ \t].*\n|\n)*", "", text)


def generate(layout_path, fetch_source=fetch_devnet):
    text = layout_path.read_text()
    layout = yaml.safe_load(text)
    source = layout.get("fixture_source")
    if not source:
        sys.exit(f"{layout_path} has no fixture_source")
    if "network_params" in layout:
        sys.exit(f"{layout_path} sets network_params; put overrides under fixture_source.network_params")

    if source["mode"] == "next-fork":
        params = next_fork_params(*fetch_source(source))
        header = f"# Generated from {source['repo']}@{source['commit']} {source['devnet']}"
    elif source["mode"] == "mainnet":
        params = mainnet_params()
        header = "# Generated in mainnet mode"
    else:
        sys.exit(f"unknown fixture_source mode {source['mode']!r}")
    apply_overrides(params, source.get("network_params") or {})

    rendered = yaml.safe_dump({"network_params": params}, sort_keys=False, default_flow_style=None, width=1000)
    lines = [f"{header} by .github/fixtures/generate-fixture.py.", "# Edit the layout and regenerate; do not edit this file.", ""]
    return "\n".join(lines) + strip_source(text).rstrip("\n") + "\n\n" + rendered


def drift(layout, fixture, fetch_source=fetch_devnet):
    """Unified diff between the committed fixture and a fresh generation; empty if equal."""
    current = fixture.read_text() if fixture.exists() else ""
    output = generate(layout, fetch_source)
    return list(difflib.unified_diff(current.splitlines(True), output.splitlines(True), str(fixture), "regenerated"))


def main(argv=None, fetch_source=fetch_devnet):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("layouts", nargs="*", type=pathlib.Path, help="layouts to generate (default: all)")
    parser.add_argument("--check", action="store_true", help="fail if a committed fixture differs")
    args = parser.parse_args(argv)

    failed = False
    for layout in args.layouts or sorted(LAYOUTS.glob("*.yaml")):
        fixture = TESTS / layout.name
        if not args.check:
            fixture.write_text(generate(layout, fetch_source))
            print(f"wrote {fixture.relative_to(ROOT)}")
            continue
        diff = drift(layout, fixture, fetch_source)
        if diff:
            failed = True
            sys.stdout.writelines(diff)
    if failed:
        sys.exit("fixtures differ from their layouts; run .github/fixtures/generate-fixture.py")


if __name__ == "__main__":
    main()
