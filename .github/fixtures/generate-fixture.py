#!/usr/bin/env python3
"""Generate a test fixture's network_params from a pinned source.

A layout in .github/fixtures/layouts/<name>.yaml holds a fixture without
network_params, plus a top-level `fixture_source` block:

  fixture_source:
    mode: next-fork            # or: mainnet
    repo: ethpandaops/glamsterdam-devnets
    commit: <full 40-hex sha>
    devnet: devnet-8
    network_params:            # optional local overrides, applied last
      seconds_per_slot: 6

The generator writes .github/tests/<name>.yaml: a header naming the source,
the layout without `fixture_source`, then the generated network_params. The result must
parse back to the layout plus network_params. `--check` regenerates every layout and fails if a
fixture differs, or if a generated fixture has no layout.
"""

import argparse
import difflib
import http.client
import json
import pathlib
import re
import sys
import time
import urllib.request

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
LAYOUTS = ROOT / ".github/fixtures/layouts"
TESTS = ROOT / ".github/tests"

FAR_FUTURE = 18446744073709551615
GENERATED_MARK = "by .github/fixtures/generate-fixture.py."
# Epoch the devnet's next fork moves to. A launch with its images pulled returns well before it; doctor.sh warns when a run did not.
NEXT_FORK_EPOCH = 2
GENESIS_DELAY = 20
SLOTS_PER_EPOCH = {"mainnet": 32, "minimal": 8}
FORKS = ["altair", "bellatrix", "capella", "deneb", "electra", "fulu", "gloas", "heze"]
MAINNET_LIVE_FORKS = ["altair", "bellatrix", "capella", "deneb", "electra", "fulu"]
# Mainnet's live blob steps as (max, target, base fee update fraction).
MAINNET_BPOS = [(15, 10, 8346193), (21, 14, 11684671)]
BPO_SLOTS = 5
OPTIONAL_KEYS = ["inclusion_list_due_bps", "slot_duration_ms_heze"]
PEERDAS_KEYS = [
    "data_column_sidecar_subnet_count",
    "samples_per_slot",
    "custody_requirement",
    "validator_custody_requirement",
    "min_epochs_for_data_column_sidecars_requests",
]


def fetch(url, attempts=3):
    # Every PR's CI runs this download, and raw.githubusercontent.com fails now and then, so ride out a blip.
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                return response.read().decode()
        except (OSError, http.client.HTTPException):
            if attempt == attempts:
                raise
            time.sleep(2 * attempt)


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
    unmapped = sorted(k for k in config if k.endswith("_FORK_EPOCH") and k[: -len("_FORK_EPOCH")].lower() not in FORKS)
    if unmapped:
        sys.exit(f"config has forks the generator does not map: {', '.join(unmapped)}")
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
    # cancun predates Electra and keeps the package default. The package has no
    # Osaka blob fields, so an osaka step must repeat prague.
    known = {"cancun", "prague", "osaka"} | {f"bpo{n}" for n in range(1, BPO_SLOTS + 1)}
    unknown = sorted(set(schedule) - known)
    if unknown:
        sys.exit(f"blobSchedule has steps the generator does not map: {', '.join(unknown)}")
    if schedule.get("osaka", schedule["prague"]) != schedule["prague"]:
        sys.exit("blobSchedule osaka differs from prague; the package has no Osaka blob fields")
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

    # An explicit list, even an empty one, stops the package adding its own raise at Gloas.
    params["gas_limit_schedule"] = [
        {"epoch": rebase(int(e["EPOCH"]), next_fork), "gas_limit": int(e["GAS_LIMIT"])}
        for e in config.get("GAS_LIMIT_SCHEDULE", [])
    ]
    for key in PEERDAS_KEYS:
        params[key] = int(config[key.upper()])
    # Settings the package models and a devnet may change; absent ones keep the package default.
    for key in OPTIONAL_KEYS:
        if key.upper() in config:
            params[key] = int(config[key.upper()])
    return params


def mainnet_params():
    # Written out, though they equal today's defaults, so the fixture keeps them
    # if the package defaults move to a newer fork or blob schedule.
    params = {"network": "kurtosis", "preset": "mainnet"}
    for fork in FORKS:
        params[f"{fork}_fork_epoch"] = 0 if fork in MAINNET_LIVE_FORKS else FAR_FUTURE
    for n in range(1, BPO_SLOTS + 1):
        if n > len(MAINNET_BPOS):
            params[f"bpo_{n}_epoch"] = FAR_FUTURE
            continue
        params[f"bpo_{n}_epoch"] = 0
        (
            params[f"bpo_{n}_max_blobs"],
            params[f"bpo_{n}_target_blobs"],
            params[f"bpo_{n}_base_fee_update_fraction"],
        ) = MAINNET_BPOS[n - 1]
    return params


def apply_overrides(params, overrides):
    """Apply layout overrides, keeping the two slot-length fields consistent."""
    # shortcut: slot_duration_ms_heze is left alone, which only matters once a source schedules Heze; adjust it then.
    params.update(overrides)
    if "seconds_per_slot" in overrides and "slot_duration_ms" not in overrides and "slot_duration_ms" in params:
        params["slot_duration_ms"] = overrides["seconds_per_slot"] * 1000
    if "slot_duration_ms" in overrides and "seconds_per_slot" not in overrides and "seconds_per_slot" in params:
        # seconds_per_slot only holds whole seconds; the package derives it otherwise.
        if overrides["slot_duration_ms"] % 1000:
            del params["seconds_per_slot"]
        else:
            params["seconds_per_slot"] = overrides["slot_duration_ms"] // 1000
    return params


def strip_source(text):
    """Remove the top-level fixture_source block (its indented and blank lines)."""
    return re.sub(r"(?m)^fixture_source:[ \t]*(?:#.*)?\n(?:[ \t].*\n|\n)*", "", text)


def generate(layout_path, fetch_source=fetch_devnet):
    text = layout_path.read_text()
    layout = yaml.safe_load(text)
    source = layout.get("fixture_source")
    if not source:
        sys.exit(f"{layout_path} has no fixture_source")
    if "network_params" in layout:
        sys.exit(f"{layout_path} sets network_params; put overrides under fixture_source.network_params")

    if source["mode"] == "next-fork":
        if not re.fullmatch(r"[0-9a-f]{40}", str(source.get("commit", ""))):
            sys.exit(f"{layout_path}: fixture_source.commit must be a full 40-hex sha, not a branch or tag, so --check is repeatable")
        params = next_fork_params(*fetch_source(source))
        header = f"# Generated from {source['repo']}@{source['commit']} {source['devnet']}"
    elif source["mode"] == "mainnet":
        params = mainnet_params()
        header = "# Generated in mainnet mode"
    else:
        sys.exit(f"unknown fixture_source mode {source['mode']!r}")
    apply_overrides(params, source.get("network_params") or {})

    rendered = yaml.safe_dump({"network_params": params}, sort_keys=False, default_flow_style=None, width=1000)
    lines = [f"{header} {GENERATED_MARK}", "# Edit the layout and regenerate; do not edit this file.", ""]
    result = "\n".join(lines) + strip_source(text).rstrip("\n") + "\n\n" + rendered
    # strip_source knows one spelling of the block; anything else must fail here, not at launch.
    expected = {**{k: v for k, v in layout.items() if k != "fixture_source"}, "network_params": params}
    try:
        parses_back = yaml.safe_load(result) == expected
    except yaml.YAMLError:
        parses_back = False
    if not parses_back:
        sys.exit(f"{layout_path}: the generated fixture does not parse back to the layout plus network_params; write fixture_source as a plain block starting at column 0")
    return result


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
    layouts = args.layouts or sorted(LAYOUTS.glob("*.yaml"))
    if args.check and not args.layouts:
        names = {layout.name for layout in layouts}
        for fixture in sorted(TESTS.glob("*.yaml")):
            if GENERATED_MARK in fixture.read_text().split("\n", 1)[0] and fixture.name not in names:
                failed = True
                print(f"{fixture} is generated but has no layout in {LAYOUTS}")
    for layout in layouts:
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
        sys.exit("fixtures differ from their layouts or have none; run .github/fixtures/generate-fixture.py, or delete fixtures whose layout is gone")
    if args.check:
        print(f"{len(layouts)} generated fixture(s) match their layouts")


if __name__ == "__main__":
    main()
