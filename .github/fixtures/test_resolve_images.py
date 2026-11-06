"""Offline tests for resolve-images.py. Run: python3 -m unittest discover -s .github/fixtures"""

import contextlib
import io
import unittest

from _loader import load

res = load("resolve-images.py")


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
