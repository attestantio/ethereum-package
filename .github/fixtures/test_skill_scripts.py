"""Offline tests for the verify-ethereum-package scripts, run against a stub `kurtosis`, a stub
`docker` and local beacon and EL servers. Run: python3 -m unittest discover -s .github/fixtures"""

import importlib.util
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / ".agents/skills/verify-ethereum-package/scripts"
SPS, SPE = 12, 32  # slow slots keep the wall clock steady while a script runs

KURTOSIS = """#!/usr/bin/env bash
case "$1" in
  enclave)
    case "${STUB_MODE:-}" in
      missing) echo "Error: No enclave found with identifier 'x'" >&2; exit 1 ;;
      down) echo "Error: connection refused" >&2; exit 1 ;;
    esac
    cat "$STUB_DIR/inspect.txt" ;;
  port) awk -v s="$4" -v p="$5" '$1 == s && $2 == p { print $3; found = 1 } END { exit !found }' "$STUB_DIR/ports.txt" ;;
  version) echo "CLI Version:   1.19.0" ;;
  *) exit 1 ;;
esac
"""
DOCKER = """#!/usr/bin/env bash
case "$1" in
  info) echo "4 CPUs, 1000 bytes memory, aarch64" ;;
  ps) [ -z "${STUB_OTEL:-}" ] || echo 0123abcd ;;
  *) exit 1 ;;
esac
"""


def find_bash():
    """A bash the scripts accept (4.4 or newer), or None."""
    for candidate in filter(None, [shutil.which("bash"), "/opt/homebrew/bin/bash", "/usr/local/bin/bash"]):
        out = subprocess.run([candidate, "-c", 'echo "${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}"'],
                             capture_output=True, text=True).stdout.split()
        if len(out) == 2 and (int(out[0]), int(out[1])) >= (4, 4):
            return candidate
    return None


BASH = find_bash()
needs_tools = unittest.skipUnless(BASH and shutil.which("jq") and shutil.which("curl"), "needs bash 4.4+, jq and curl")


class Node:
    """One beacon node with its execution client. `lag` is how many slots the head is behind the wall
    clock. A field set to None is a request the node does not answer. `up=False` refuses connections.
    `el_up=False` is a stopped EL: kurtosis lists no port for it."""

    def __init__(self, lag=1, peers=2, el_head=None, finalized=None, justified=None, up=True, el_up=True):
        self.lag, self.peers, self.el_head, self.finalized, self.justified, self.up = lag, peers, el_head, finalized, justified, up
        self.el_up = el_up


def root_of(slot):
    return "0x" + f"{slot:064x}"


def beacon(node, genesis, wall):
    head, epoch = wall - node.lag, wall // SPE
    finalized = epoch - 2 if node.finalized is None else node.finalized
    justified = epoch - 1 if node.justified is None else node.justified

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, body, code=200):
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            path = self.path
            if path == "/eth/v1/config/spec":
                return self.send({"data": {"SECONDS_PER_SLOT": str(SPS), "SLOTS_PER_EPOCH": str(SPE), "PRESET_BASE": "mainnet",
                                           "CONFIG_NAME": "stub", "DEPOSIT_CHAIN_ID": "1", "GLOAS_FORK_EPOCH": "2"}})
            if path == "/eth/v1/beacon/genesis":
                return self.send({"data": {"genesis_time": str(genesis)}})
            if path == "/eth/v1/beacon/headers/head":
                return self.send({"data": {"header": {"message": {"slot": str(head)}}}})
            if path == "/eth/v1/node/peer_count":
                return self.send({}, 404) if node.peers is None else self.send({"data": {"connected": str(node.peers)}})
            if path == "/eth/v1/node/version":
                return self.send({"data": {"version": "StubBeacon/v1"}})
            if path == "/eth/v1/beacon/states/head/validators":
                return self.send({"data": [{}] * 64})
            if path == "/eth/v1/beacon/states/head/finality_checkpoints":
                return self.send({"data": {"current_justified": {"epoch": str(justified)},
                                           "finalized": {"epoch": str(finalized), "root": root_of(finalized * SPE)}}})
            match = re.fullmatch(r"/eth/v1/beacon/blocks/(\d+)/root", path)
            if match and int(match.group(1)) <= head:
                return self.send({"data": {"root": root_of(int(match.group(1)))}})
            self.send({}, 404)

    return Handler


def execution(node, wall):
    height = node.el_head if node.el_head is not None else wall - node.lag

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            method = json.loads(self.rfile.read(int(self.headers["Content-Length"])))["method"]
            result = {"eth_blockNumber": hex(height), "web3_clientVersion": "StubGeth/v1"}[method]
            data = json.dumps({"jsonrpc": "2.0", "id": 1, "result": result}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    return Handler


class StubEnclave:
    """Serves the nodes, and puts a `kurtosis` and a `docker` on PATH that describe them."""

    def __init__(self, nodes, wall=200):
        self.nodes, self.wall = nodes, wall

    def __enter__(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="stub-enclave-"))
        self.genesis = int(time.time()) - self.wall * SPS - 1
        self.servers, services, ports = [], [], []
        for i, node in enumerate(self.nodes, 1):
            for kind, name, port_name, handler in (
                ("cl", f"cl-{i}-lighthouse-geth", "http", beacon(node, self.genesis, self.wall)),
                ("el", f"el-{i}-geth-lighthouse", "rpc", execution(node, self.wall)),
            ):
                services.append(name)
                if kind == "el" and not node.el_up:
                    continue
                if kind == "cl" and not node.up:
                    ports.append(f"{name} {port_name} http://127.0.0.1:1")
                    continue
                server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
                threading.Thread(target=server.serve_forever, daemon=True).start()
                self.servers.append(server)
                ports.append(f"{name} {port_name} http://127.0.0.1:{server.server_address[1]}")
        (self.tmp / "inspect.txt").write_text("Name: stub\nUUID: 0123456789abcdef\nStatus: RUNNING\n" + "\n".join(services) + "\n")
        (self.tmp / "ports.txt").write_text("\n".join(ports) + "\n")
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for name, text in (("kurtosis", KURTOSIS), ("docker", DOCKER)):
            (bin_dir / name).write_text(text)
            (bin_dir / name).chmod(0o755)
        self.bin = bin_dir
        return self

    def __exit__(self, *exc):
        for server in self.servers:
            server.shutdown()
            server.server_close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run(self, script, *args, mode="", cwd=ROOT, env=None):
        env = dict(os.environ, STUB_DIR=str(self.tmp), STUB_MODE=mode, PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}", **(env or {}))
        return subprocess.run([BASH, str(SCRIPTS / script), *args], env=env, capture_output=True, text=True, cwd=cwd, timeout=180)


def healthy(count=3, **kw):
    return [Node(**kw) for _ in range(count)]


@needs_tools
class DevnetHealthTest(unittest.TestCase):
    def health(self, nodes, wall=200, epoch="5", **kw):
        with StubEnclave(nodes, wall) as enclave:
            return enclave.run("devnet-health.sh", "stub", *([epoch] if epoch is not None else []), **kw)

    def test_agreeing_nodes_are_healthy(self):
        r = self.health(healthy())
        self.assertEqual((r.returncode, r.stdout.splitlines()[-1]), (0, "RESULT: HEALTHY"), r.stdout)

    def test_health_epoch_is_required(self):
        r = self.health(healthy(), epoch=None)
        self.assertEqual(r.returncode, 2)
        self.assertIn("usage", r.stderr)

    def test_run_shorter_than_the_health_epoch_is_incomplete(self):
        self.assertEqual(self.health(healthy(), wall=2 * SPE + 3).returncode, 4)

    def test_finality_is_judged_from_the_health_epoch_not_a_fixed_one(self):
        # Wall-clock epoch 6, nothing finalized, health epoch 8: too early to judge, not a failure.
        r = self.health(healthy(finalized=0), wall=6 * SPE + 3, epoch="8")
        self.assertEqual(r.returncode, 4, r.stdout)
        self.assertEqual(self.health(healthy(finalized=0), wall=6 * SPE + 3, epoch="5").returncode, 1)

    def test_el_far_behind_its_peers_is_diverged(self):
        nodes = healthy(3, el_head=290) + [Node(el_head=0)]
        r = self.health(nodes, wall=300)
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertRegex(r.stdout, r"DIVERGED el-4-geth-lighthouse: block 0 is 290 behind the highest EL block 290")

    def test_a_stopped_el_is_diverged_and_prints_no_curl_error(self):
        r = self.health(healthy(3) + [Node(el_up=False)])
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertIn("DIVERGED el-4-geth-lighthouse: no answer to eth_blockNumber", r.stdout)
        self.assertEqual(r.stderr, "")

    def test_one_of_two_nodes_stalled_inside_the_search_window_is_diverged(self):
        r = self.health([Node(), Node(lag=10)])
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertIn("stalled", r.stdout)

    def test_one_of_two_nodes_stalled_beyond_the_search_window_leaves_no_majority(self):
        self.assertEqual(self.health([Node(), Node(lag=20)]).returncode, 1)

    def test_one_of_three_nodes_stalled_is_diverged(self):
        self.assertEqual(self.health([Node(), Node(), Node(lag=20)]).returncode, 3)

    def test_a_lone_beacon_node_has_no_peers_by_design(self):
        r = self.health([Node(peers=0)])
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_unanswered_peer_count_is_not_zero_peers(self):
        r = self.health([Node(), Node(), Node(peers=None)])
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("? peers", r.stdout)

    def test_zero_peers_among_several_nodes_is_diverged(self):
        r = self.health([Node(), Node(), Node(peers=0)])
        self.assertEqual(r.returncode, 3, r.stdout)

    def test_unknown_enclave_and_failed_inspect_are_told_apart(self):
        missing = self.health(healthy(1), mode="missing")
        self.assertEqual(missing.returncode, 2)
        self.assertIn("not found", missing.stderr)
        down = self.health(healthy(1), mode="down")
        self.assertEqual(down.returncode, 2)
        self.assertIn("does not prove the enclave is absent", down.stderr)
        self.assertIn("connection refused", down.stderr)

    @unittest.skipUnless(os.path.exists("/bin/bash") and subprocess.run(
        ["/bin/bash", "-c", "(( BASH_VERSINFO[0] < 4 ))"]).returncode == 0, "no old /bin/bash here")
    def test_old_bash_is_refused_up_front(self):
        r = subprocess.run(["/bin/bash", str(SCRIPTS / "devnet-health.sh"), "stub", "5"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn("bash 4.4 or newer", r.stderr)


@needs_tools
class SetupAfterTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = pathlib.Path(tmp.name) / "run"

    def test_records_the_served_network(self):
        with StubEnclave(healthy(2)) as enclave:
            r = enclave.run("setup-after.sh", "stub", str(self.dir))
            text = (self.dir / "SETUP-after.md").read_text()
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("StubBeacon/v1", text)
            self.assertIn("StubGeth/v1", text)
            self.assertIn("Validators at head: 64", text)
            self.assertIn(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(enclave.genesis)), text)
            self.assertIn("GLOAS=2", text)

    def test_falls_back_to_a_beacon_node_that_answers(self):
        with StubEnclave([Node(up=False), Node()]) as enclave:
            r = enclave.run("setup-after.sh", "stub", str(self.dir))
            text = (self.dir / "SETUP-after.md").read_text()
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("cl-1-lighthouse-geth: unavailable", text)
            self.assertIn("cl-2-lighthouse-geth: StubBeacon/v1", text)
            self.assertNotIn("1970-01-01", text)

    def test_no_answering_beacon_node_writes_nothing(self):
        with StubEnclave([Node(up=False), Node(up=False)]) as enclave:
            r = enclave.run("setup-after.sh", "stub", str(self.dir))
        self.assertEqual(r.returncode, 1)
        self.assertIn("not written", r.stderr)
        self.assertFalse(self.dir.exists())

    def test_never_overwrites_an_existing_record(self):
        self.dir.mkdir()
        (self.dir / "SETUP-after.md").write_text("hand-written differences\n")
        with StubEnclave(healthy(1)) as enclave:
            r = enclave.run("setup-after.sh", "stub", str(self.dir))
        self.assertEqual(r.returncode, 1)
        self.assertEqual((self.dir / "SETUP-after.md").read_text(), "hand-written differences\n")

    def test_unknown_enclave_leaves_no_directory(self):
        with StubEnclave(healthy(1)) as enclave:
            r = enclave.run("setup-after.sh", "stub", str(self.dir), mode="missing")
        self.assertEqual(r.returncode, 2)
        self.assertFalse(self.dir.exists())


@needs_tools
class SetupBeforeTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = pathlib.Path(tmp.name)
        self.dir = self.tmp / "run"
        self.args = self.tmp / "args.yaml"

    def run_script(self, *args):
        with StubEnclave(healthy(1)) as enclave:
            return enclave.run("setup-before.sh", *args)

    def test_images_table_has_one_row_per_pinned_image(self):
        self.args.write_text('participants:\n  - el_type: geth\n    el_image: "x/geth:1@sha256:aa"\n    cl_type: teku\n    cl_image: y/teku:2\n')
        r = self.run_script(str(self.args), str(self.dir))
        text = (self.dir / "SETUP-before.md").read_text()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("| el_image (line 3) | `x/geth:1@sha256:aa` |", text)
        self.assertIn("| cl_image (line 5) | `y/teku:2` |", text)
        self.assertNotIn("3:    el_image", text)

    def test_no_pinned_images_means_package_defaults(self):
        self.args.write_text("participants:\n  - el_type: geth\n")
        self.run_script(str(self.args), str(self.dir))
        self.assertIn("| all | package defaults |", (self.dir / "SETUP-before.md").read_text())

    def test_records_whether_the_otel_log_stack_is_running(self):
        self.args.write_text("participants: []\n")
        other = self.tmp / "run2"
        with StubEnclave(healthy(1)) as enclave:
            enclave.run("setup-before.sh", str(self.args), str(self.dir))
            enclave.run("setup-before.sh", str(self.args), str(other), env={"STUB_OTEL": "1"})
        self.assertIn("OTel log stack: not running", (self.dir / "SETUP-before.md").read_text())
        self.assertIn("OTel log stack: running", (other / "SETUP-before.md").read_text())

    def test_missing_args_file_writes_nothing(self):
        r = self.run_script(str(self.tmp / "gone.yaml"), str(self.dir))
        self.assertEqual(r.returncode, 2)
        self.assertFalse(self.dir.exists())

    def test_refuses_to_overwrite_and_leaves_no_temp_file(self):
        self.args.write_text("participants: []\n")
        self.assertEqual(self.run_script(str(self.args), str(self.dir)).returncode, 0)
        self.assertEqual(self.run_script(str(self.args), str(self.dir)).returncode, 1)
        self.assertEqual([p.name for p in self.dir.iterdir()], ["SETUP-before.md"])


@needs_tools
class DoctorTest(unittest.TestCase):
    def test_bad_epoch_argument_is_a_usage_error(self):
        with StubEnclave(healthy(1)) as enclave:
            r = enclave.run("doctor.sh", "stub", "abc")
        self.assertEqual(r.returncode, 2)
        self.assertIn("usage", r.stderr)

    def test_failed_inspect_says_so(self):
        with StubEnclave(healthy(1)) as enclave:
            r = enclave.run("doctor.sh", "stub", mode="down")
        self.assertEqual(r.returncode, 2)
        self.assertIn("does not prove the enclave is absent", r.stderr)


class ScriptRulesTest(unittest.TestCase):
    def test_sed_lines_avoid_escapes_that_bsd_sed_lacks(self):
        # BSD sed (macOS) has no \s, \S, \d or \w; use POSIX classes such as [[:space:]].
        for script in SCRIPTS.glob("*.sh"):
            for number, line in enumerate(script.read_text().splitlines(), 1):
                if re.search(r"\bsed\b", line) and re.search(r"\\[sSdwW]", line):
                    self.fail(f"{script.name}:{number} uses a GNU-only escape in sed: {line.strip()}")

    def test_nothing_evals_a_command_without_checking_it_first(self):
        # `eval "$(cmd)"` returns 0 when cmd fails and prints nothing, so a later step runs on blank values.
        for path in (ROOT / ".agents/skills/verify-ethereum-package").rglob("*"):
            if path.is_file() and path.suffix in (".sh", ".md"):
                for number, line in enumerate(path.read_text().splitlines(), 1):
                    if 'eval "$(' in line:
                        self.fail(f"{path.relative_to(ROOT)}:{number} evals a command substitution directly; assign it, check it, then eval")

    @unittest.skipUnless(importlib.util.find_spec("markdown"), "needs the markdown package")
    def test_review_page_shows_tag_like_text_as_text(self):
        with tempfile.TemporaryDirectory() as tmp:
            (pathlib.Path(tmp) / "REPORT.md").write_text("Remove `<full-uuid>`, then <image-id> and <img src=x onerror=alert(1)>\n")
            subprocess.run([sys.executable, str(SCRIPTS / "review_page.py"), tmp], check=True, capture_output=True)
            page = (pathlib.Path(tmp) / "index.html").read_text()
        self.assertIn("&lt;image-id&gt;", page)
        self.assertIn("&lt;img src=x onerror=alert(1)&gt;", page)
        self.assertNotIn("<img", page)


if __name__ == "__main__":
    unittest.main()
