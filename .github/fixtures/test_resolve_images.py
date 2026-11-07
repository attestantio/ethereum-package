"""Offline tests for resolve-images.py. Run: python3 -m unittest discover -s .github/fixtures"""

import contextlib
import io
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

import yaml

from _loader import load

res = load("resolve-images.py")
gen = load("generate-fixture.py")


class ResolveTest(unittest.TestCase):
    def test_release_image_tags(self):
        self.assertEqual(res.CLIENTS["geth"].image_tag("v1.17.8"), "v1.17.8")
        self.assertEqual(res.CLIENTS["vouch"].image_tag("v1.13.1"), "1.13.1")
        self.assertEqual(res.CLIENTS["nimbus"].image_tag("v26.10.0"), "multiarch-v26.10.0")

    def test_commit_tag_matches_branch_and_digest(self):
        tags = [
            {"name": "master-linux-amd64-9e80021", "digest": "sha256:a"},
            {"name": "master-1111111", "digest": "sha256:b"},
            {"name": "master-9e80021", "digest": "sha256:a"},
        ]
        self.assertEqual(res.commit_tag("master", "sha256:a", tags), ("master-9e80021", "9e80021"))
        self.assertEqual(res.commit_tag("master", "sha256:c", tags), (None, None))


    def test_registry_detection(self):
        self.assertTrue(res.on_docker_hub("ethpandaops/geth"))
        self.assertFalse(res.on_docker_hub("ghcr.io/paradigmxyz/reth"))

    def test_fixture_pins(self):
        fixture = {"participants": [
            {"el_type": "geth", "el_image": "g:1", "cl_type": "prysm", "cl_image": "p:1", "vc_image": "pv:1"},
            {"el_type": "besu", "cl_type": "nimbus", "vc_type": "vouch", "vc_image": "v:1", "dirk_image": "d:1"},
            {"el_type": "reth", "cl_type": "teku", "vc_type": "teku"},
        ]}
        pins = res.fixture_pins(fixture)
        self.assertEqual(sorted(pins), ["besu", "dirk", "geth", "nimbus", "prysm", "prysm_validator", "reth", "teku", "vouch"])
        self.assertEqual(pins["prysm_validator"], {"pv:1"})
        self.assertEqual(pins["dirk"], {"d:1"})
        self.assertEqual(pins["besu"], set())  # package default

    def test_newer_devnets(self):
        names = ["devnet-8", "devnet-9", "devnet-12", "msf-2", "devnet-x"]
        self.assertEqual(res.newer_devnets(names, "devnet-8"), ["devnet-9", "devnet-12"])
        self.assertEqual(res.newer_devnets(names, "devnet-12"), [])

    def test_check_compares_with_pins_and_reads_source(self):
        text = ("# Generated from o/r@abc1234 devnet-8 by .github/fixtures/generate-fixture.py.\n"
                "participants:\n  - el_type: geth\n    el_image: e/geth:1@sha256:a\n    cl_type: teku\n"
                "    cl_image: e/teku:1@sha256:c\n    vc_type: vouch\n    vc_image: a/vouch:2.0.0-alpha.1@sha256:d\n"
                "    dirk_image: a/dirk:1@sha256:e\n")
        self.assertEqual(res.SOURCE_HEADER.search(text).groups(), ("o/r", "abc1234", "devnet-8"))
        lines = {"geth": "geth: e/geth:1@sha256:a  # why", "teku": "teku: e/teku:2@sha256:b  # why",
                 "vouch": "vouch: a/vouch:1.9.0@sha256:f  # latest release", "dirk": "dirk: a/dirk:2@sha256:g  # why"}
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertFalse(res.compare_pins(res.yaml.safe_load(text), lambda name: lines[name]))
        printed = out.getvalue()
        self.assertIn("same       geth: e/geth:1@sha256:a", printed)
        self.assertIn("differs    teku: e/teku:2@sha256:b  # why\n           pinned e/teku:1@sha256:c", printed)
        self.assertIn("prerelease vouch:", printed)
        self.assertIn("differs    dirk:", printed)
        self.assertIn("summary: 1 same, 2 differs, 1 prerelease, 0 errors", printed)

    def test_latest_replaces_only_differing_pins(self):
        fixture = {"participants": [
            {"el_type": "geth", "el_image": "e/geth:1@sha256:a", "cl_type": "teku", "cl_image": "e/teku:1@sha256:c",
             "vc_type": "vouch", "vc_image": "a/vouch:2.0.0-alpha.1@sha256:d"}]}
        lines = {"geth": "geth: e/geth:1@sha256:a  # why", "teku": "teku: e/teku:2@sha256:b  # why",
                 "vouch": "vouch: a/vouch:1.9.0@sha256:f  # latest release", "dirk": "dirk: a/dirk:2@sha256:g  # why"}
        updates = {}
        with contextlib.redirect_stdout(io.StringIO()):
            res.compare_pins(fixture, lambda name: lines[name], updates)
        self.assertEqual(updates, {"e/teku:1@sha256:c": "e/teku:2@sha256:b"})  # same and prerelease pins stay
        text = "x: e/teku:1@sha256:c\n"
        self.assertTrue(res.latest_text(text, updates).endswith("x: e/teku:2@sha256:b\n"))
        self.assertIn("not the pinned fixture", res.latest_text(text, updates).splitlines()[0])

    def compare(self, pin, release):
        """Status line and updates for a Vouch pin against a latest release."""
        fixture = {"participants": [{"el_type": "geth", "cl_type": "teku", "vc_type": "vouch", "vc_image": pin}]}
        lines = {"geth": "geth: g:1  # why", "teku": "teku: t:1  # why", "dirk": "dirk: d:1  # why",
                 "vouch": f"vouch: attestant/vouch:{release}@sha256:f  # latest release"}
        updates = {}
        with contextlib.redirect_stdout(io.StringIO()) as out:
            res.compare_pins(fixture, lambda name: lines[name], updates)
        status = next(line.split()[0] for line in out.getvalue().splitlines() if "vouch:" in line)
        return status, updates

    def test_prerelease_is_ahead_only_while_its_version_is_above_the_release(self):
        ahead = "attestant/vouch:2.0.0-alpha.1@sha256:a"
        self.assertEqual(self.compare(ahead, "1.9.0")[0], "prerelease")
        self.assertEqual(self.compare("attestant/vouch:1.14.0-rc.1@sha256:a", "1.13.1")[0], "prerelease")
        # The release the alpha led to is out: the pin is stale and `latest` replaces it.
        stale = "attestant/vouch:1.14.0-alpha.2@sha256:a"
        status, updates = self.compare(stale, "1.14.0")
        self.assertEqual(status, "differs")
        self.assertEqual(updates, {stale: "attestant/vouch:1.14.0@sha256:f"})
        self.assertEqual(self.compare(stale, "1.15.0")[0], "differs")
        self.assertEqual(self.compare("attestant/vouch:1.13.1@sha256:a", "1.14.0")[0], "differs")

    def test_docker_failure_reports_docker_reason(self):
        failure = subprocess.CalledProcessError(1, ["docker"], stderr="ERROR: some noise\nERROR: toomanyrequests: pull rate limit\n")
        with mock.patch.object(res.subprocess, "run", side_effect=failure):
            with self.assertRaises(RuntimeError) as raised:
                res.inspect("x/y:1")
        self.assertEqual(str(raised.exception), "ERROR: toomanyrequests: pull rate limit")
        with contextlib.redirect_stdout(io.StringIO()) as out, mock.patch.object(res.subprocess, "run", side_effect=failure), \
                mock.patch.object(res, "latest_release", return_value="v1.0.0"):
            res.compare_pins({"participants": [{"el_type": "geth"}]}, lambda name: res.release_line(name, "latest release"))
        self.assertIn("error      geth: ERROR: toomanyrequests", out.getvalue())

    def test_unmapped_client_is_named(self):
        with self.assertRaises(RuntimeError) as raised:
            res.release_line("grandine", "latest release")
        self.assertEqual(str(raised.exception), "no release mapping for grandine")

    def test_nimbus_execution_and_validator_images_do_not_share_the_consensus_key(self):
        pins = res.fixture_pins({"participants": [
            {"el_type": "nimbus", "el_image": "statusim/nimbus-eth1:x", "cl_type": "nimbus", "cl_image": "statusim/nimbus-eth2:y",
             "vc_type": "nimbus", "vc_image": "statusim/nimbus-validator-client:z"},
            {"el_type": "geth", "cl_type": "nimbus"},
        ]})
        self.assertEqual(pins["nimbus"], {"statusim/nimbus-eth2:y"})
        self.assertEqual(pins["nimbus_el"], {"statusim/nimbus-eth1:x"})
        self.assertEqual(pins["nimbus_validator"], {"statusim/nimbus-validator-client:z"})
        self.assertNotIn("nimbus_validator", res.fixture_pins({"participants": [{"el_type": "geth", "cl_type": "nimbus"}]}))

    def test_latest_replaces_whole_values_only(self):
        text = 'a: x/geth:1\nb: "x/geth:1.2"\nc: x/geth:1 # pinned\nd: x/geth:1@sha256:aa\n'
        out = res.latest_text(text, {"x/geth:1": "y/geth:9"})
        self.assertEqual(out.splitlines()[1:], ['a: y/geth:9', 'b: "x/geth:1.2"', 'c: y/geth:9 # pinned', 'd: x/geth:1@sha256:aa'])

    def test_latest_refuses_to_overwrite_the_fixture(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "fixture.yaml"
            path.write_text("participants: []\n")
            with self.assertRaises(SystemExit) as raised:
                res.main(["latest", str(path), str(path)])
            self.assertIn("must not be the fixture itself", str(raised.exception.code))
            self.assertEqual(path.read_text(), "participants: []\n")

    def test_source_header_matches_what_the_generator_writes(self):
        layout = ("participants:\n  - el_type: geth\n\nfixture_source:\n  mode: next-fork\n  repo: ethpandaops/glamsterdam-devnets\n"
                  f"  commit: {'b' * 40}\n  devnet: devnet-8\n")
        config = yaml.load("PRESET_BASE: mainnet\nSLOT_DURATION_MS: 12000\nGENESIS_FORK_VERSION: 0x1\nDEPOSIT_CHAIN_ID: 1\n"
                           "DEPOSIT_CONTRACT_ADDRESS: 0x0\nGLOAS_FORK_EPOCH: 5\n"
                           + "".join(f"{f}_FORK_EPOCH: 0\n{f}_FORK_VERSION: 0x2\n" for f in ("ALTAIR", "BELLATRIX", "CAPELLA", "DENEB", "ELECTRA", "FULU"))
                           + "GLOAS_FORK_VERSION: 0x3\nHEZE_FORK_EPOCH: 18446744073709551615\nHEZE_FORK_VERSION: 0x4\n"
                           + "".join(f"{k}: 1\n" for k in ("DATA_COLUMN_SIDECAR_SUBNET_COUNT", "SAMPLES_PER_SLOT", "CUSTODY_REQUIREMENT",
                                                         "VALIDATOR_CUSTODY_REQUIREMENT", "MIN_EPOCHS_FOR_DATA_COLUMN_SIDECARS_REQUESTS")),
                           Loader=yaml.BaseLoader)
        genesis = {"timestamp": "0", "gasLimit": "0x1", "config": {"blobSchedule": {"prague": {"target": 6, "max": 9, "baseFeeUpdateFraction": 1}}}}
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "layout.yaml"
            path.write_text(layout)
            text = gen.generate(path, lambda source: (config, genesis))
        self.assertEqual(res.SOURCE_HEADER.search(text).groups(), ("ethpandaops/glamsterdam-devnets", "b" * 40, "devnet-8"))

    def test_one_failing_client_does_not_stop_the_run(self):
        def resolve(name):
            if name == "bad":
                raise RuntimeError("registry down")
            return f"{name}: ok"
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertTrue(res.resolve_all(["bad", "good"], resolve))
        self.assertIn("good: ok", out.getvalue())


if __name__ == "__main__":
    unittest.main()
