"""Offline tests for resolve-images.py. Run: python3 -m unittest discover -s .github/fixtures"""

import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location(
    "resolve_images", pathlib.Path(__file__).resolve().parent / "resolve-images.py")
res = importlib.util.module_from_spec(spec)
spec.loader.exec_module(res)


class ResolveTest(unittest.TestCase):
    def test_release_wins_only_when_newer_than_advertised_commit(self):
        self.assertTrue(res.choose("2026-10-01T00:00:00Z", "2026-10-02T00:00:00Z"))
        self.assertFalse(res.choose("2026-10-02T00:00:00Z", "2026-10-01T00:00:00Z"))
        self.assertFalse(res.choose(None, "2026-10-01T00:00:00Z"))

    def test_release_image_tags(self):
        self.assertEqual(res.release_image_tag("geth", "v1.17.8"), "v1.17.8")
        self.assertEqual(res.release_image_tag("vouch", "v1.13.1"), "1.13.1")
        self.assertEqual(res.release_image_tag("nimbus", "v26.10.0"), "multiarch-v26.10.0")


if __name__ == "__main__":
    unittest.main()
