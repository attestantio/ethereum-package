"""Offline tests for generate-fixture.py. Run: python3 -m unittest discover -s .github/fixtures"""

import contextlib
import io
import pathlib
import tempfile
import unittest

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
  commit: abc123
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


    def test_unknown_blob_step_fails(self):
        genesis = {**GENESIS, "config": {**GENESIS["config"], "blobSchedule": {**GENESIS["config"]["blobSchedule"], "osaka": {}}}}
        with self.assertRaises(SystemExit) as raised:
            gen.next_fork_params(yaml.load(CONFIG, Loader=yaml.BaseLoader), genesis)
        self.assertIn("osaka", str(raised.exception.code))

    def test_check_exits_nonzero_on_drift(self):
        layouts = self.dir / "layouts"
        tests = self.dir / "tests"
        layouts.mkdir()
        tests.mkdir()
        (layouts / "f.yaml").write_text(LAYOUT.format(mode="next-fork"))
        (tests / "f.yaml").write_text("hand edited\n")
        self.addCleanup(setattr, gen, "LAYOUTS", gen.LAYOUTS)
        self.addCleanup(setattr, gen, "TESTS", gen.TESTS)
        gen.LAYOUTS, gen.TESTS = layouts, tests
        with self.assertRaises(SystemExit) as raised, contextlib.redirect_stdout(io.StringIO()):
            gen.main(["--check"], fake_fetch)
        self.assertIn("differ", str(raised.exception.code))


if __name__ == "__main__":
    unittest.main()
