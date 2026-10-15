#!/usr/bin/env python3
"""Print digest-pinned client images for a fixture. Read-only: pulls nothing, edits nothing.

  resolve-images.py mainnet [client ...]
      Latest stable release of each client.
  resolve-images.py next-fork <repo> <commit> <devnet> [client ...]
      The image the devnet advertises, pinned to its commit tag and digest,
      unless the client's latest stable release contains that commit.
      Advertised tags float: the pin is the build the tag points at today,
      not at the devnet commit. Record the date with the pins.

Output is one line per client: `<client>: <image ref>  # <why> <platforms>`.
Needs docker (buildx imagetools) and access to GitHub and Docker Hub. Set
GITHUB_TOKEN to avoid GitHub's unauthenticated rate limit.
"""

import json
import os
import re
import subprocess
import sys
import urllib.request
from typing import NamedTuple

import yaml


class Client(NamedTuple):
    repo: str  # GitHub repository that publishes releases
    image: str  # official image repository
    tag_format: str = "{}"  # release tag -> image tag
    strip_v: bool = False  # image tags drop the release tag's leading "v"

    def image_tag(self, release_tag):
        return self.tag_format.format(release_tag.lstrip("v") if self.strip_v else release_tag)


CLIENTS = {
    "geth": Client("ethereum/go-ethereum", "ethereum/client-go"),
    "lighthouse": Client("sigp/lighthouse", "sigp/lighthouse"),
    "prysm": Client("OffchainLabs/prysm", "offchainlabs/prysm-beacon-chain"),
    "prysm_validator": Client("OffchainLabs/prysm", "offchainlabs/prysm-validator"),
    "lodestar": Client("ChainSafe/lodestar", "chainsafe/lodestar"),
    "teku": Client("Consensys/teku", "consensys/teku"),
    "nimbus": Client("status-im/nimbus-eth2", "statusim/nimbus-eth2", "multiarch-{}"),
    "nethermind": Client("NethermindEth/nethermind", "nethermind/nethermind"),
    "besu": Client("hyperledger/besu", "hyperledger/besu"),
    "erigon": Client("erigontech/erigon", "erigontech/erigon"),
    "reth": Client("paradigmxyz/reth", "ghcr.io/paradigmxyz/reth"),
    "vouch": Client("attestantio/vouch", "attestant/vouch", strip_v=True),
    "dirk": Client("attestantio/dirk", "attestant/dirk", strip_v=True),
}
IMAGES_FILE = "ansible/inventories/{devnet}/group_vars/all/images.yaml"


def get_json(url):
    request = urllib.request.Request(url)
    if url.startswith("https://api.github.com/") and os.environ.get("GITHUB_TOKEN"):
        request.add_header("Authorization", "Bearer " + os.environ["GITHUB_TOKEN"])
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def latest_release(repo):
    return get_json(f"https://api.github.com/repos/{repo}/releases/latest")["tag_name"]


def contains(repo, tag, sha):
    """True if release tag contains commit sha: the compare base..head is ahead or identical."""
    status = get_json(f"https://api.github.com/repos/{repo}/compare/{sha}...{tag}")["status"]
    return status in ("ahead", "identical")


def inspect(ref):
    """Digest and platforms of an image, from its registry manifest."""
    out = subprocess.run(
        ["docker", "buildx", "imagetools", "inspect", ref, "--format", "{{json .}}"],
        check=True, capture_output=True, text=True,
    ).stdout
    data = json.loads(out)
    manifest = data["manifest"]
    platforms = sorted({f"{m['platform']['os']}/{m['platform']['architecture']}"
                        for m in manifest.get("manifests", []) if m["platform"]["os"] != "unknown"})
    if not platforms and "image" in data:
        platforms = [f"{data['image']['os']}/{data['image']['architecture']}"]
    return manifest["digest"], platforms


def commit_tag(branch, digest, tags):
    """The `<branch>-<sha>` tag published with the same digest, and its sha."""
    pattern = re.compile(rf"^{re.escape(branch)}-([0-9a-f]{{7,40}})$")
    for tag in tags:
        match = pattern.match(tag["name"])
        if match and tag["digest"] == digest:
            return tag["name"], match.group(1)
    return None, None


def on_docker_hub(image):
    # Docker Hub repositories have no registry host before the first slash.
    return "." not in image.split("/", 1)[0]


def hub_tags(image, branch):
    url = f"https://hub.docker.com/v2/repositories/{image}/tags?page_size=100&ordering=last_updated&name={branch}-"
    return get_json(url)["results"]


def release_line(name, why):
    client = CLIENTS[name]
    tag = latest_release(client.repo)
    ref = f"{client.image}:{client.image_tag(tag)}"
    digest, platforms = inspect(ref)
    return f"{name}: {ref}@{digest}  # {why} {','.join(platforms)}"


def next_fork_line(name, advertised):
    image, branch = advertised.rsplit(":", 1)
    digest, platforms = inspect(advertised)
    if not on_docker_hub(image):
        return f"{name}: {advertised}@{digest}  # advertised; commit tag lookup needs Docker Hub {','.join(platforms)}"
    tag, sha = commit_tag(branch, digest, hub_tags(image, branch))
    if tag is None:
        return f"{name}: {advertised}@{digest}  # advertised; no commit tag matches this digest {','.join(platforms)}"
    if name not in CLIENTS:
        return f"{name}: {image}:{tag}@{digest}  # advertised {advertised}; no release mapping, release not checked {','.join(platforms)}"
    client = CLIENTS[name]
    release = latest_release(client.repo)
    if contains(client.repo, release, sha):
        return release_line(name, f"release {release} contains advertised {tag}")
    return f"{name}: {image}:{tag}@{digest}  # advertised {advertised} {','.join(platforms)}"


def resolve_all(names, resolve):
    """Print one line per client; a failing client prints an error and the run continues."""
    failed = False
    for name in names:
        try:
            print(resolve(name))
        except Exception as error:  # one client's registry or API error must not hide the rest
            failed = True
            print(f"{name}: ERROR {error}")
    return failed


def main(argv):
    if len(argv) >= 1 and argv[0] == "mainnet":
        if resolve_all(argv[1:] or CLIENTS, lambda name: release_line(name, "latest release")):
            sys.exit(1)
        return
    if len(argv) >= 4 and argv[0] == "next-fork":
        repo, commit, devnet = argv[1:4]
        url = f"https://raw.githubusercontent.com/{repo}/{commit}/{IMAGES_FILE.format(devnet=devnet)}"
        with urllib.request.urlopen(url, timeout=30) as response:
            advertised = yaml.safe_load(response)["default_ethereum_client_images"]
        if resolve_all(argv[4:] or advertised, lambda name: next_fork_line(name, advertised[name])):
            sys.exit(1)
        return
    print(__doc__, file=sys.stderr)
    sys.exit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
