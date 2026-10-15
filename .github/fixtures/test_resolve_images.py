"""Offline tests for resolve-images.py. Run: python3 -m unittest discover -s .github/fixtures"""

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
        self.assertEqual(res.commit_tag("ethpandaops/geth", "master", "sha256:a", tags), ("master-9e80021", "9e80021"))
        self.assertEqual(res.commit_tag("ethpandaops/geth", "master", "sha256:c", tags), (None, None))


if __name__ == "__main__":
    unittest.main()
