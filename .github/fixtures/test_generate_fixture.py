"""Offline tests for generate-fixture.py. Run: python3 -m unittest discover -s .github/fixtures"""

import contextlib
import http.client
import io
import pathlib
import tempfile
import unittest
import urllib.error
from unittest import mock

import yaml

from _loader import load

gen = load("generate-fixture.py")

FAR = gen.FAR_FUTURE
CONFIG = """
PRESET_BASE: 'mainnet'
GENESIS_FORK_VERSION: 0x10733183
ALTAIR_FORK_VERSION: 0x20733183
ALTAIR_FORK_EPOCH: 0
BELLATRIX_FORK_VERSION: 0x30733183
BELLATRIX_FORK_EPOCH: 0
CAPELLA_FORK_VERSION: 0x40733183
CAPELLA_FORK_EPOCH: 0
DENEB_FORK_VERSION: 0x50733183
DENEB_FORK_EPOCH: 0
ELECTRA_FORK_VERSION: 0x60733183
ELECTRA_FORK_EPOCH: 0
FULU_FORK_VERSION: 0x70733183
FULU_FORK_EPOCH: 0
GLOAS_FORK_VERSION: 0x80733183
GLOAS_FORK_EPOCH: 1536
HEZE_FORK_VERSION: 0x90000000
HEZE_FORK_EPOCH: 18446744073709551615
SLOT_DURATION_MS: 12000
MIN_BUILDER_WITHDRAWABILITY_DELAY: 64
DEPOSIT_CHAIN_ID: 7091047534
DEPOSIT_CONTRACT_ADDRESS: 0x00000000219ab540356cBB839Cbe05303d7705Fa
DATA_COLUMN_SIDECAR_SUBNET_COUNT: 128
SAMPLES_PER_SLOT: 8
CUSTODY_REQUIREMENT: 4
VALIDATOR_CUSTODY_REQUIREMENT: 8
MIN_EPOCHS_FOR_DATA_COLUMN_SIDECARS_REQUESTS: 4096
BLOB_SCHEDULE:
  - EPOCH: 0
    MAX_BLOBS_PER_BLOCK: 21
GAS_LIMIT_SCHEDULE:
  - EPOCH: 1566
    GAS_LIMIT: 200000000
"""

# Two BPO steps at genesis and a third 1600 epochs in, at 12s slots.
GENESIS = {
    "timestamp": "1786622400",
    "gasLimit": "0x3938700",
    "config": {
        "blobSchedule": {
            "prague": {"target": 6, "max": 9, "baseFeeUpdateFraction": 5007716},
            "bpo1": {"target": 10, "max": 15, "baseFeeUpdateFraction": 8346193},
            "bpo2": {"target": 14, "max": 21, "baseFeeUpdateFraction": 11684671},
            "bpo3": {"target": 20, "max": 30, "baseFeeUpdateFraction": 16692386},
        },
        "bpo1Time": 0,
        "bpo2Time": 0,
        "bpo3Time": 1786622400 + 1600 * 384,
    },
}

LAYOUT = """# Comment kept in the fixture.
participants:
  - el_type: geth
    cl_type: lighthouse

fixture_source:
  mode: {mode}
  repo: ethpandaops/glamsterdam-devnets
  commit: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  devnet: devnet-8
  network_params:
    seconds_per_slot: 6

# Column-0 comment after the source block, kept.
additional_services: []
"""


def fake_fetch(source):
    return yaml.load(CONFIG, Loader=yaml.BaseLoader), GENESIS


class GenerateTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = pathlib.Path(tmp.name)

    def layout(self, mode="next-fork"):
        path = self.dir / "layout.yaml"
        path.write_text(LAYOUT.format(mode=mode))
        return path

    def params(self, mode="next-fork"):
        return yaml.safe_load(gen.generate(self.layout(mode), fake_fetch))["network_params"]

    def test_next_fork_moves_to_epoch_2_and_keeps_offsets(self):
        p = self.params()
        self.assertEqual(p["fulu_fork_epoch"], 0)
        self.assertEqual(p["gloas_fork_epoch"], 2)
        self.assertEqual(p["heze_fork_epoch"], FAR)
        self.assertEqual(p["gas_limit_schedule"], [{"epoch": 32, "gas_limit": 200000000}])
        self.assertEqual(p["bpo_3_epoch"], 66)

    def test_next_fork_copies_identity_and_derives_blob_targets(self):
        p = self.params()
        self.assertEqual(p["network_id"], "7091047534")
        self.assertEqual(p["gloas_fork_version"], "0x80733183")
        self.assertEqual(p["genesis_gaslimit"], 60000000)
        self.assertEqual(
            (p["bpo_1_epoch"], p["bpo_1_max_blobs"], p["bpo_1_target_blobs"], p["bpo_1_base_fee_update_fraction"]),
            (0, 15, 10, 8346193),
        )
        self.assertEqual((p["bpo_2_max_blobs"], p["bpo_2_target_blobs"]), (21, 14))
        self.assertEqual(p["bpo_4_epoch"], FAR)
        self.assertEqual(p["target_blobs_per_block_electra"], 6)
        self.assertEqual(p["base_fee_update_fraction_electra"], 5007716)
        self.assertEqual(p["genesis_delay"], 20)

    def test_slot_override_keeps_both_slot_fields_consistent(self):
        p = self.params()
        self.assertEqual((p["seconds_per_slot"], p["slot_duration_ms"]), (6, 6000))

    def test_mainnet_mode_starts_on_fulu(self):
        p = self.params("mainnet")
        self.assertEqual(p["fulu_fork_epoch"], 0)
        self.assertEqual(p["gloas_fork_epoch"], FAR)
        self.assertNotIn("network_id", p)
        self.assertEqual((p["bpo_2_epoch"], p["bpo_2_max_blobs"], p["bpo_2_target_blobs"]), (0, 21, 14))
        self.assertEqual(p["bpo_3_epoch"], FAR)

    def test_layout_text_is_kept_without_fixture_source(self):
        text = gen.generate(self.layout(), fake_fetch)
        self.assertIn("# Comment kept in the fixture.", text)
        self.assertIn("additional_services: []", text)
        self.assertIn("# Column-0 comment after the source block, kept.", text)
        self.assertNotIn("fixture_source", text)

    def test_drift_fails_on_hand_edit(self):
        layout = self.layout()
        fixture = self.dir / "fixture.yaml"
        fixture.write_text(gen.generate(layout, fake_fetch))
        self.assertEqual(gen.drift(layout, fixture, fake_fetch), [])
        fixture.write_text(fixture.read_text().replace("gloas_fork_epoch: 2", "gloas_fork_epoch: 5"))
        self.assertNotEqual(gen.drift(layout, fixture, fake_fetch), [])


    def with_blob_step(self, name, step):
        schedule = {**GENESIS["config"]["blobSchedule"], name: step}
        return {**GENESIS, "config": {**GENESIS["config"], "blobSchedule": schedule}}

    def test_unknown_blob_step_fails(self):
        with self.assertRaises(SystemExit) as raised:
            gen.next_fork_params(yaml.load(CONFIG, Loader=yaml.BaseLoader), self.with_blob_step("amsterdam", {}))
        self.assertIn("amsterdam", str(raised.exception.code))

    def test_osaka_blob_step_must_repeat_prague(self):
        config = yaml.load(CONFIG, Loader=yaml.BaseLoader)
        prague = GENESIS["config"]["blobSchedule"]["prague"]
        gen.next_fork_params(config, self.with_blob_step("osaka", dict(prague)))
        with self.assertRaises(SystemExit) as raised:
            gen.next_fork_params(config, self.with_blob_step("osaka", {**prague, "max": prague["max"] + 1}))
        self.assertIn("osaka", str(raised.exception.code))

    def test_fractional_slot_override_drops_seconds_per_slot(self):
        p = gen.apply_overrides({"seconds_per_slot": 6, "slot_duration_ms": 6000}, {"slot_duration_ms": 1500})
        self.assertEqual(p, {"slot_duration_ms": 1500})

    def check_dirs(self):
        layouts, tests = self.dir / "layouts", self.dir / "tests"
        layouts.mkdir(exist_ok=True)
        tests.mkdir(exist_ok=True)
        self.addCleanup(setattr, gen, "LAYOUTS", gen.LAYOUTS)
        self.addCleanup(setattr, gen, "TESTS", gen.TESTS)
        gen.LAYOUTS, gen.TESTS = layouts, tests
        return layouts, tests

    def check(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            try:
                gen.main(["--check"], fake_fetch)
            except SystemExit as raised:
                return str(raised.code), out.getvalue()
        return None, out.getvalue()

    def test_check_exits_nonzero_on_drift(self):
        layouts, tests = self.check_dirs()
        (layouts / "f.yaml").write_text(LAYOUT.format(mode="next-fork"))
        (tests / "f.yaml").write_text("hand edited\n")
        code, _ = self.check()
        self.assertIn("differ", code)

    def test_check_passes_and_counts_the_layouts_it_checked(self):
        layouts, tests = self.check_dirs()
        (layouts / "f.yaml").write_text(LAYOUT.format(mode="next-fork"))
        (tests / "f.yaml").write_text(gen.generate(layouts / "f.yaml", fake_fetch))
        code, out = self.check()
        self.assertIsNone(code)
        self.assertIn("1 generated fixture(s) match", out)

    def test_check_fails_on_a_generated_fixture_whose_layout_is_gone(self):
        layouts, tests = self.check_dirs()
        (layouts / "f.yaml").write_text(LAYOUT.format(mode="next-fork"))
        (tests / "f.yaml").write_text(gen.generate(layouts / "f.yaml", fake_fetch))
        (layouts / "f.yaml").unlink()
        code, out = self.check()
        self.assertIn("have none", code)
        self.assertIn("f.yaml is generated but has no layout", out)

    def test_check_ignores_hand_written_fixtures(self):
        _, tests = self.check_dirs()
        (tests / "hand.yaml").write_text("# Written by hand.\nparticipants: []\n")
        code, out = self.check()
        self.assertIsNone(code)
        self.assertIn("0 generated fixture(s)", out)

    def test_commit_must_be_a_full_hex_sha(self):
        for commit in ("master", "abc123", "A" * 40):
            layout = self.dir / "branch.yaml"
            layout.write_text(LAYOUT.format(mode="next-fork").replace("a" * 40, commit))
            with self.assertRaises(SystemExit) as raised:
                gen.generate(layout, fake_fetch)
            self.assertIn("40-hex", str(raised.exception.code), commit)

    def test_fork_the_generator_does_not_map_fails(self):
        config = yaml.load(CONFIG + "EIP7928_FORK_EPOCH: 1000\n", Loader=yaml.BaseLoader)
        with self.assertRaises(SystemExit) as raised:
            gen.next_fork_params(config, GENESIS)
        self.assertIn("EIP7928_FORK_EPOCH", str(raised.exception.code))

    def test_copies_inclusion_list_and_heze_slot_duration_when_the_source_sets_them(self):
        config = yaml.load(CONFIG + "INCLUSION_LIST_DUE_BPS: 6667\nSLOT_DURATION_MS_HEZE: 6000\n", Loader=yaml.BaseLoader)
        p = gen.next_fork_params(config, GENESIS)
        self.assertEqual((p["inclusion_list_due_bps"], p["slot_duration_ms_heze"]), (6667, 6000))
        p = gen.next_fork_params(yaml.load(CONFIG, Loader=yaml.BaseLoader), GENESIS)
        self.assertNotIn("inclusion_list_due_bps", p)
        self.assertNotIn("slot_duration_ms_heze", p)

    def test_a_source_without_a_gas_limit_schedule_gets_an_empty_one(self):
        config = yaml.load(CONFIG.split("GAS_LIMIT_SCHEDULE:")[0], Loader=yaml.BaseLoader)
        self.assertEqual(gen.next_fork_params(config, GENESIS)["gas_limit_schedule"], [])

    def test_electra_blob_values_come_from_prague(self):
        p = self.params()
        self.assertEqual((p["max_blobs_per_block_electra"], p["target_blobs_per_block_electra"]), (9, 6))

    def test_mainnet_blob_steps(self):
        p = self.params("mainnet")
        self.assertEqual(
            [(p[f"bpo_{n}_max_blobs"], p[f"bpo_{n}_target_blobs"], p[f"bpo_{n}_base_fee_update_fraction"]) for n in (1, 2)],
            [(15, 10, 8346193), (21, 14, 11684671)],
        )

    def test_fixture_source_spellings_the_stripper_misses_fail_instead_of_launching_broken(self):
        spellings = {
            "flow mapping": "fixture_source: {mode: mainnet}\n",
            "quoted key": '"fixture_source":\n  mode: mainnet\n',
            "column-0 comment inside the block": "fixture_source:\n  mode: mainnet\n# note\n  repo: x\n",
        }
        for label, block in spellings.items():
            layout = self.dir / "odd.yaml"
            layout.write_text("participants:\n  - el_type: geth\n\n" + block)
            with self.assertRaises(SystemExit, msg=label) as raised:
                gen.generate(layout, fake_fetch)
            self.assertIn("does not parse back", str(raised.exception.code), label)

    def test_a_comment_after_the_fixture_source_key_is_stripped(self):
        layout = self.dir / "commented.yaml"
        layout.write_text(LAYOUT.format(mode="mainnet").replace("fixture_source:", "fixture_source:  # pinned devnet"))
        self.assertNotIn("fixture_source", gen.generate(layout, fake_fetch))


class FetchTest(unittest.TestCase):
    def fetch(self, *outcomes):
        """Run gen.fetch with urlopen returning or raising each outcome in turn. Returns the result or error, the urlopen calls and the sleeps."""
        with mock.patch.object(gen.urllib.request, "urlopen", side_effect=outcomes) as urlopen, mock.patch.object(gen.time, "sleep") as sleep:
            try:
                result = gen.fetch("https://example.test/config.yaml")
            except (OSError, http.client.HTTPException) as error:
                result = error
        return result, urlopen.call_count, [call.args[0] for call in sleep.call_args_list]

    def test_transient_failures_are_retried_with_a_growing_pause(self):
        outcomes = (urllib.error.URLError("reset"), http.client.IncompleteRead(b"par"), io.BytesIO(b"body"))
        self.assertEqual(self.fetch(*outcomes), ("body", 3, [2, 4]))

    def test_the_last_error_is_raised_after_three_attempts(self):
        result, calls, sleeps = self.fetch(*[urllib.error.URLError(f"reset {n}") for n in range(3)])
        self.assertEqual((str(result.reason), calls, sleeps), ("reset 2", 3, [2, 4]))


if __name__ == "__main__":
    unittest.main()
