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
    base = "https://raw.githubusercontent.com/{repo}/{commit}/network-configs/{devnet}/metadata".format(**source)
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
    epochs = {fork: int(config[fork.upper() + "_FORK_EPOCH"]) for fork in FORKS}
    scheduled = [e for e in epochs.values() if e not in (0, FAR_FUTURE)]
    if not scheduled:
        sys.exit("source schedules no fork after genesis")
    next_fork = min(scheduled)
    slot_ms = int(config["SLOT_DURATION_MS"])

    params = {
        "network": "kurtosis",
        "preset": config["PRESET_BASE"],
        "network_id": str(config["DEPOSIT_CHAIN_ID"]),
        "deposit_contract_address": config["DEPOSIT_CONTRACT_ADDRESS"],
        "seconds_per_slot": slot_ms // 1000,
        "slot_duration_ms": slot_ms,
        "genesis_delay": GENESIS_DELAY,
        "genesis_gaslimit": int(genesis["gasLimit"], 16),
        "genesis_fork_version": config["GENESIS_FORK_VERSION"],
    }
    if "MIN_BUILDER_WITHDRAWABILITY_DELAY" in config:
        params["min_builder_withdrawability_delay"] = int(config["MIN_BUILDER_WITHDRAWABILITY_DELAY"])
    for fork in FORKS:
        params[fork + "_fork_epoch"] = rebase(epochs[fork], next_fork)
        params[fork + "_fork_version"] = config[fork.upper() + "_FORK_VERSION"]

    electra_max = int(config["MAX_BLOBS_PER_BLOCK_ELECTRA"])
    params["max_blobs_per_block_electra"] = electra_max
    params["target_blobs_per_block_electra"] = electra_max * 2 // 3
    schedule = config.get("BLOB_SCHEDULE", [])
    if len(schedule) > BPO_SLOTS:
        sys.exit("BLOB_SCHEDULE has more entries than the package's bpo slots")
    for n in range(1, BPO_SLOTS + 1):
        if n <= len(schedule):
            entry = schedule[n - 1]
            blobs = int(entry["MAX_BLOBS_PER_BLOCK"])
            params["bpo_%d_epoch" % n] = rebase(int(entry["EPOCH"]), next_fork)
            params["bpo_%d_max_blobs" % n] = blobs
            params["bpo_%d_target_blobs" % n] = blobs * 2 // 3
        else:
            params["bpo_%d_epoch" % n] = FAR_FUTURE

    gas = config.get("GAS_LIMIT_SCHEDULE", [])
    if gas:
        params["gas_limit_schedule"] = [
            {"epoch": rebase(int(e["EPOCH"]), next_fork), "gas_limit": int(e["GAS_LIMIT"])} for e in gas
        ]
    for key in PEERDAS_KEYS:
        params[key] = int(config[key.upper()])
    return params


def mainnet_params():
    params = {"network": "kurtosis", "preset": "mainnet"}
    for fork in FORKS:
        params[fork + "_fork_epoch"] = 0 if fork in MAINNET_LIVE_FORKS else FAR_FUTURE
    return params


def render_value(value):
    if isinstance(value, str):
        return '"%s"' % value
    if isinstance(value, list):
        items = ", ".join("{%s}" % ", ".join("%s: %s" % (k, render_value(v)) for k, v in item.items()) for item in value)
        return "[%s]" % items
    return str(value)


def strip_source(text):
    """Remove the top-level fixture_source block from the layout text."""
    return re.sub(r"(?m)^fixture_source:\n(?:[ #].*\n|\n)*", "", text)


def generate(layout_path, fetch_source=fetch_devnet):
    text = layout_path.read_text()
    layout = yaml.safe_load(text)
    source = layout.get("fixture_source")
    if not source:
        sys.exit("%s has no fixture_source" % layout_path)
    if "network_params" in layout:
        sys.exit("%s sets network_params; put overrides under fixture_source.network_params" % layout_path)

    if source["mode"] == "next-fork":
        params = next_fork_params(*fetch_source(source))
        header = "# Generated from {repo}@{commit} {devnet}".format(**source)
    elif source["mode"] == "mainnet":
        params = mainnet_params()
        header = "# Generated in mainnet mode"
    else:
        sys.exit("unknown fixture_source mode %r" % source["mode"])
    params.update(source.get("network_params") or {})

    lines = [header + " by .github/fixtures/generate-fixture.py.", "# Edit the layout and regenerate; do not edit this file.", ""]
    body = strip_source(text).rstrip("\n")
    lines += [body, "", "network_params:"]
    lines += ["  %s: %s" % (key, render_value(value)) for key, value in params.items()]
    return "\n".join(lines) + "\n"


def drift(layout, fixture, fetch_source=fetch_devnet):
    """Unified diff between the committed fixture and a fresh generation; empty if equal."""
    current = fixture.read_text() if fixture.exists() else ""
    output = generate(layout, fetch_source)
    return list(difflib.unified_diff(current.splitlines(True), output.splitlines(True), str(fixture), "regenerated"))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("layouts", nargs="*", type=pathlib.Path, help="layouts to generate (default: all)")
    parser.add_argument("--check", action="store_true", help="fail if a committed fixture differs")
    args = parser.parse_args()

    failed = False
    for layout in args.layouts or sorted(LAYOUTS.glob("*.yaml")):
        fixture = TESTS / layout.name
        if not args.check:
            fixture.write_text(generate(layout))
            print("wrote %s" % fixture.relative_to(ROOT))
            continue
        diff = drift(layout, fixture)
        if diff:
            failed = True
            sys.stdout.writelines(diff)
    if failed:
        sys.exit("fixtures differ from their layouts; run .github/fixtures/generate-fixture.py")


if __name__ == "__main__":
    main()
