#!/usr/bin/env python3
"""Print digest-pinned client images for a fixture. Read-only: pulls nothing, edits nothing.

  resolve-images.py mainnet [client ...]
      Latest stable release of each client.
  resolve-images.py next-fork <repo> <commit> <devnet> [client ...]
      The image the devnet advertises, pinned to its commit tag and digest,
      unless the client has a stable release newer than that commit.

Output is one line per client: `<client>: <image ref>  # <why> [<platforms>]`.
Needs docker (buildx imagetools), curl access to GitHub and Docker Hub.
"""

import json
import os
import re
import subprocess
import sys
import urllib.request

import yaml

# client: (GitHub repo, official image, release tag -> image tag)
CLIENTS = {
    "geth": ("ethereum/go-ethereum", "ethereum/client-go", "{}"),
    "lighthouse": ("sigp/lighthouse", "sigp/lighthouse", "{}"),
    "prysm": ("OffchainLabs/prysm", "offchainlabs/prysm-beacon-chain", "{}"),
    "prysm_validator": ("OffchainLabs/prysm", "offchainlabs/prysm-validator", "{}"),
    "lodestar": ("ChainSafe/lodestar", "chainsafe/lodestar", "{}"),
    "teku": ("Consensys/teku", "consensys/teku", "{}"),
    "nimbus": ("status-im/nimbus-eth2", "statusim/nimbus-eth2", "multiarch-{}"),
    "nethermind": ("NethermindEth/nethermind", "nethermind/nethermind", "{}"),
    "besu": ("hyperledger/besu", "hyperledger/besu", "{}"),
    "erigon": ("erigontech/erigon", "erigontech/erigon", "{}"),
    "reth": ("paradigmxyz/reth", "ghcr.io/paradigmxyz/reth", "{}"),
    "vouch": ("attestantio/vouch", "attestant/vouch", "{}"),
    "dirk": ("attestantio/dirk", "attestant/dirk", "{}"),
}
IMAGES_FILE = "ansible/inventories/{devnet}/group_vars/all/images.yaml"


def get_json(url):
    request = urllib.request.Request(url)
    # Unauthenticated GitHub API calls are limited to 60 an hour.
    if url.startswith("https://api.github.com/") and os.environ.get("GITHUB_TOKEN"):
        request.add_header("Authorization", "Bearer " + os.environ["GITHUB_TOKEN"])
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def latest_release(repo):
    release = get_json("https://api.github.com/repos/%s/releases/latest" % repo)
    return release["tag_name"], release["published_at"]


def release_image_tag(client, tag):
    _, _, template = CLIENTS[client]
    if client in ("vouch", "dirk"):
        tag = tag.lstrip("v")
    return template.format(tag)


def inspect(ref):
    """Digest and platforms of an image, from its registry manifest."""
    out = subprocess.run(
        ["docker", "buildx", "imagetools", "inspect", ref, "--format", "{{json .}}"],
        check=True, capture_output=True, text=True,
    ).stdout
    data = json.loads(out)
    manifest = data["manifest"]
    platforms = sorted({"%s/%s" % (m["platform"]["os"], m["platform"]["architecture"])
                        for m in manifest.get("manifests", []) if m["platform"]["os"] != "unknown"})
    if not platforms and "image" in data:
        platforms = ["%s/%s" % (data["image"]["os"], data["image"]["architecture"])]
    return manifest["digest"], platforms


def commit_tag(image, branch, digest):
    """The `<branch>-<sha>` tag that ethpandaops published with the same digest."""
    url = "https://hub.docker.com/v2/repositories/%s/tags?page_size=100&ordering=last_updated&name=%s-" % (image, branch)
    pattern = re.compile(r"^%s-([0-9a-f]{7,40})$" % re.escape(branch))
    for tag in get_json(url)["results"]:
        match = pattern.match(tag["name"])
        if match and tag["digest"] == digest:
            return tag["name"], match.group(1)
    return None, None


def commit_date(repo, sha):
    return get_json("https://api.github.com/repos/%s/commits/%s" % (repo, sha))["commit"]["committer"]["date"]


def choose(advertised_date, release_date):
    """Use the release only if it is newer than the advertised commit (ISO 8601 UTC strings)."""
    return release_date is not None and advertised_date is not None and release_date > advertised_date


def release_line(client, why):
    repo, image, _ = CLIENTS[client]
    tag, _ = latest_release(repo)
    ref = "%s:%s" % (image, release_image_tag(client, tag))
    digest, platforms = inspect(ref)
    return "%s: %s@%s  # %s %s" % (client, ref, digest, why, ",".join(platforms))


def next_fork_line(client, advertised):
    image, branch = advertised.rsplit(":", 1)
    digest, platforms = inspect(advertised)
    tag, sha = commit_tag(image, branch, digest)
    if tag is None:
        return "%s: %s@%s  # advertised; no commit tag matches this digest %s" % (client, advertised, digest, ",".join(platforms))
    if client in CLIENTS:
        repo = CLIENTS[client][0]
        release_tag, release_date = latest_release(repo)
        if choose(commit_date(repo, sha), release_date):
            return release_line(client, "release %s is newer than advertised %s" % (release_tag, tag))
    return "%s: %s:%s@%s  # advertised %s %s" % (client, image, tag, digest, advertised, ",".join(platforms))


def main(argv):
    if len(argv) >= 1 and argv[0] == "mainnet":
        for client in argv[1:] or CLIENTS:
            print(release_line(client, "latest release"))
        return
    if len(argv) >= 4 and argv[0] == "next-fork":
        repo, commit, devnet = argv[1:4]
        url = "https://raw.githubusercontent.com/%s/%s/%s" % (repo, commit, IMAGES_FILE.format(devnet=devnet))
        with urllib.request.urlopen(url, timeout=30) as response:
            advertised = yaml.safe_load(response)["default_ethereum_client_images"]
        for client in argv[4:] or advertised:
            print(next_fork_line(client, advertised[client]))
        return
    sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
