"""Offline tests for .github/tests/assert-vouch-dirk-five-pair.sh, run against a stub `kurtosis` and
local HTTP servers for the beacon node and every metrics endpoint, so real HTTP statuses are exercised.
Run: python3 -m unittest discover -s .github/fixtures"""

import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from test_skill_scripts import BASH, needs_tools

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".github/tests/assert-vouch-dirk-five-pair.sh"
FORK_SLOT = 64  # GLOAS_FORK_EPOCH 2 x 32 slots
BEACON = "cl-2-lighthouse-nethermind"
VC_A, VC_B, VC_P = "vc-4-erigon-lodestar-vouch", "vc-5-besu-nimbus-vouch", "vc-6-geth-lighthouse-vouch"
DIRKS = [f"dirk-{c}-{n}" for c in "ab" for n in (1, 2, 3)]
ATT = 'vouch_attestation_process_requests_total{result="succeeded"}'
PROP = 'vouch_beaconblockproposal_process_requests_total{result="succeeded"}'
ACCOUNTS = 'vouch_accountmanager_accounts_total{state="active_ongoing"}'
REAL_CONFIGS = {  # as a real run rendered them
    vc: (ROOT / ".github/fixtures/testdata" / name).read_text()
    for vc, name in ((VC_A, "vouch-cluster-a.yml"), (VC_B, "vouch-cluster-b-active.yml"), (VC_P, "vouch-cluster-b-passive.yml"))}


def pubkey(i):
    return "0x" + f"{i:096x}"


def root(slot):
    return "0xaa" + f"{slot:062x}"


class Net:
    """A chain of Gloas blocks from the fork to `head`, after one Fulu block. Proposers cycle through
    natives, cluster a and cluster b. A slot in `unbuilt` has a payload the next block does not build
    on; a slot in `missing` has no block; a slot in `errors` answers with that HTTP status, or with
    nothing for "close"."""

    def __init__(self, natives=range(0, 384), a=range(384, 448), b=range(448, 512), head=90, unbuilt=(),
                 missing=(), errors=None, bid=True, version="gloas", only=None, head_body=None, genesis_body=None):
        self.natives, self.a, self.b, self.head = list(natives), list(a), list(b), head
        self.errors, self.version, self.bid = errors or {}, version, bid
        self.head_body, self.genesis_body = head_body, genesis_body
        self.blocks, self.by_root = {}, {root(FORK_SLOT - 1): FORK_SLOT - 1}
        last_full, last_root = "0x" + "0" * 64, root(FORK_SLOT - 1)
        for slot in range(FORK_SLOT, head + 1):
            if slot in missing:
                continue
            kind = {1: self.a, 5: self.b}.get(slot % 8, self.natives)
            if only == "a" and kind is self.b or only == "b" and kind is self.a:
                kind = self.natives
            self.blocks[slot] = {"proposer": kind[slot % len(kind)], "parent": last_full, "hash": f"0x{slot:064x}",
                                 "parent_root": last_root}
            self.by_root[root(slot)] = slot
            last_root = root(slot)
            if slot not in unbuilt:
                last_full = f"0x{slot:064x}"
        self.genesis = [{"index": str(i), "validator": {"pubkey": pubkey(i)}}
                        for i in sorted(self.natives + self.a + self.b)]

    def block_json(self, slot):
        if slot == FORK_SLOT - 1:
            return {"version": "fulu", "data": {"message": {"slot": str(slot), "parent_root": root(slot - 1), "body": {}}}}
        block = self.blocks[slot]
        fields = ({"parent_block_hash": block["parent"], "block_hash": block["hash"]} if self.bid is True
                  else {"parent_block_hash": None, "block_hash": None})
        body = {"signed_execution_payload_bid": {"message": fields}} if self.bid else {}
        return {"version": self.version, "data": {"message": {"slot": str(slot), "proposer_index": str(block["proposer"]),
                                                              "parent_root": block["parent_root"], "body": body}}}


def vouch_yml(cluster, accounts, delays=None, beacons=(1, 2, 3, 4, 5), dirks=(1, 2, 3)):
    """The shape src/vc/vouch.star renders."""
    lines = ["log-level: 'info'", "beacon-node-addresses:"] + [f"  - 'http://cl-{n}-client-el:4000'" for n in beacons]
    lines += ["accountmanager:", "  dirk:", "    endpoints:"] + [f"      - 'dirk-{cluster}-{n}:8881'" for n in dirks]
    lines += ["    client-cert: 'file:///certs/client.crt'", "    accounts:"]
    lines += [f"      - 'DistributedWallet/{n}'" for n in accounts] + ["    timeout: '30s'", "strategies:", "  beaconblockproposal:", "    style: 'best'"]
    if delays:
        lines += ["multiinstance:", "  style: 'static-delay'", "  static-delay:", f"    attester-delay: '{delays[0]}'", f"    proposer-delay: '{delays[1]}'"]
    return "\n".join(lines + ["blockrelay:", "  fallback-gas-limit: 30000000", "graffiti:", "  static:", "    value: 'x'"]) + "\n"


def vouch_metrics(att=0, prop=0, accounts=64):
    """Prometheus text of one Vouch. A series that never counted is absent, as in a real run."""
    lines = ["# HELP vouch_x help", f'{ACCOUNTS} {accounts}']
    lines += [f"{ATT} {att}", f"{PROP} {prop}"] if att or prop else []
    return "\n".join(lines) + "\n"


def dirk_metrics(att=0, prop=0, denied=0):
    return "\n".join([
        f'dirk_signer_process_requests_total{{request="attestation",result="succeeded"}} {att}',
        f'dirk_signer_process_requests_total{{request="generic",result="succeeded"}} 34272',
        f'dirk_signer_process_requests_total{{request="proposal",result="succeeded"}} {prop}',
        f'dirk_signer_process_requests_total{{request="proposal",result="denied"}} {denied}']) + "\n"


def healthy_metrics(a_count=64, b_count=64):
    metrics = {VC_A: vouch_metrics(451, 26, a_count), VC_B: vouch_metrics(458, 28, b_count), VC_P: vouch_metrics(0, 0, b_count)}
    for peer in DIRKS:  # each peer signs what Vouch reports, and a little more
        metrics[peer] = dirk_metrics(att=479, prop=29)
    return metrics


def handler(routes):
    """A server answering `routes`, a function from a path to (status, body). A status of None sends nothing."""
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            code, body = routes(self.path)
            if code is None:
                return
            data = body if isinstance(body, bytes) else (body.encode() if isinstance(body, str) else json.dumps(body).encode())
            self.send_response(code)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
    return Handler


KURTOSIS = """#!/usr/bin/env bash
case "$1 $2" in
  "port print") awk -v s="$4" -v p="$5" '$1 == s && $2 == p { print $3, $4; found = 1 } END { exit !found }' "$STUB_DIR/ports.txt" ;;
  "service exec") [ -f "$STUB_DIR/exec/$4.yml" ] || exit 1; echo "The command was successfully executed and returned '0'."; cat "$STUB_DIR/exec/$4.yml" ;;
  "files download") [ -d "$STUB_DIR/files/$4" ] || exit 1; mkdir -p "$5"; cp "$STUB_DIR/files/$4"/* "$5"/ ;;
  *) exit 1 ;;
esac
"""


class Enclave:
    """Serves the beacon node and the metrics endpoints, and puts a `kurtosis` on PATH that describes them."""

    def __init__(self, net=None, metrics=None, configs=None, drop=()):
        self.net = net or Net()
        a_count, b_count = len(self.net.a), len(self.net.b)
        self.metrics = {**healthy_metrics(a_count, b_count), **(metrics or {})}
        accounts_a, accounts_b = range(0, a_count), range(a_count, a_count + b_count)
        self.configs = {VC_A: vouch_yml("a", accounts_a), VC_B: vouch_yml("b", accounts_b, ("250ms", "500ms")),
                        VC_P: vouch_yml("b", accounts_b, ("4s", "2s")), **(configs or {})}
        self.drop, self.requests = set(drop), []

    def __enter__(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="stub-five-pair-"))
        self.servers, ports = [], []

        def serve(name, port_id, routes):
            server = ThreadingHTTPServer(("127.0.0.1", 0), handler(routes))
            threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True).start()
            self.servers.append(server)
            ports.append(f"{name} {port_id} 127.0.0.1 {server.server_address[1]}")

        net = self.net

        def beacon(path):
            if path == "/eth/v1/beacon/states/genesis/validators":
                return 200, net.genesis_body if net.genesis_body is not None else {"data": net.genesis}
            match = re.fullmatch(r"/eth/v2/beacon/blocks/(head|0x[0-9a-f]+)", path)
            if match:
                if match.group(1) == "head" and net.head_body is not None:
                    return 200, net.head_body
                slot = net.head if match.group(1) == "head" else net.by_root.get(match.group(1))
                if slot is None:
                    return 404, {"code": 404}
                if slot in net.errors:
                    return (None, None) if net.errors[slot] == "close" else (net.errors[slot], {})
                return 200, net.block_json(slot)
            return 404, {}

        serve(BEACON, "http", beacon)
        for service, text in self.metrics.items():
            if service not in self.drop:
                serve(service, "metrics", lambda path, s=service, t=text: (self.requests.append(s) or 200, t) if path == "/metrics" else (404, ""))
        (self.tmp / "ports.txt").write_text("\n".join(ports) + "\n")
        (self.tmp / "exec").mkdir()
        for service, text in self.configs.items():
            if text is not None:
                (self.tmp / "exec" / f"{service}.yml").write_text(text)
        for cluster, indices in (("a", net.a), ("b", net.b)):
            folder = self.tmp / "files" / f"dkg-validators-file-{cluster}"
            folder.mkdir(parents=True)
            (folder / "validators.txt").write_text("# DKG validator pubkeys for genesis\n" + "".join(
                f"{pubkey(i)}:0x010000000000000000000000abcdef:32000000000\n" for i in indices))
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "kurtosis").write_text(KURTOSIS)
        (bin_dir / "kurtosis").chmod(0o755)
        self.bin = bin_dir
        return self

    def __exit__(self, *exc):
        for server in self.servers:
            server.shutdown()
            server.server_close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run(self, bash=None):
        env = dict(os.environ, STUB_DIR=str(self.tmp), PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}")
        return subprocess.run([bash or BASH, str(SCRIPT), "stub"], env=env, capture_output=True, text=True, timeout=120)


def check(bash=None, **kw):
    with Enclave(**kw) as enclave:
        result = enclave.run(bash)
        result.requests = enclave.requests
        return result


def old_bash():
    """macOS's bash 3.2, which the script must still run under."""
    try:
        out = subprocess.run(["/bin/bash", "-c", "echo ${BASH_VERSINFO[0]}"], capture_output=True, text=True).stdout.strip()
    except OSError:
        return None
    return "/bin/bash" if out.isdigit() and int(out) < 4 else None


def fail_lines(r):
    return [line for line in r.stdout.splitlines() if line.startswith("FAIL")]


@needs_tools
class GloasWalkTest(unittest.TestCase):
    def assertResult(self, r, code, word):
        self.assertEqual((r.returncode, r.stdout.splitlines()[-1] if r.stdout else ""), (code, f"RESULT: {word}"), r.stdout + r.stderr)

    def test_healthy_enclave_passes(self):
        r = check()
        self.assertResult(r, 0, "PASS")
        self.assertIn("cluster a:", r.stdout)
        self.assertIn("cluster b:", r.stdout)

    @unittest.skipUnless(old_bash(), "needs bash 3.2")
    def test_the_script_runs_under_bash_3_2(self):
        self.assertResult(check(bash=old_bash()), 0, "PASS")

    def test_a_payload_the_next_block_does_not_build_on_fails_and_names_the_slot_and_cluster(self):
        r = check(net=Net(unbuilt={73}))  # 73 % 8 == 1: cluster a
        self.assertResult(r, 1, "FAIL")
        self.assertEqual(len(fail_lines(r)), 1, r.stdout)
        self.assertRegex(r.stdout, r"FAIL .*slot 73 \(cluster a\)")

    def test_a_native_validators_unbuilt_payload_is_not_a_cluster_failure(self):
        self.assertResult(check(net=Net(unbuilt={70})), 0, "PASS")  # 70 % 8 == 6: a native

    def test_both_clusters_are_reported_when_both_fail(self):
        r = check(net=Net(unbuilt={73, 77}))  # 77 % 8 == 5: cluster b
        self.assertResult(r, 1, "FAIL")
        self.assertRegex(r.stdout, r"slot 73 \(cluster a\)")
        self.assertRegex(r.stdout, r"slot 77 \(cluster b\)")

    def test_blocks_without_a_payload_bid_fail(self):
        for name, bid in (("absent", False), ("null", "null")):
            with self.subTest(name):
                r = check(net=Net(bid=bid))
                self.assertResult(r, 1, "FAIL")
                self.assertIn("no payload bid", r.stdout)

    def test_a_server_error_on_a_block_is_not_an_empty_slot(self):
        for name, error in (("an HTTP 500", 500), ("a closed connection", "close")):
            with self.subTest(name):
                r = check(net=Net(errors={73: error}))
                self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
                self.assertEqual(r.stdout.splitlines()[-1], "RESULT: ERROR")
                self.assertIn(root(73), r.stderr)  # the block it could not read
                self.assertIn("slot 74", r.stderr)  # and the child that named it

    def test_a_server_error_does_not_hide_an_unbuilt_payload(self):
        self.assertEqual(check(net=Net(unbuilt={73}, errors={73: 500})).returncode, 2)

    def test_a_missed_slot_is_not_a_failure(self):
        self.assertResult(check(net=Net(missing={85})), 0, "PASS")

    def test_a_head_that_is_not_a_block_could_not_be_checked(self):
        r = check(net=Net(head_body="<html>bad gateway</html>"))
        self.assertEqual((r.returncode, r.stdout.splitlines()[-1]), (2, "RESULT: ERROR"), r.stdout + r.stderr)

    def test_a_head_without_a_version_could_not_be_checked(self):
        r = check(net=Net(head_body='{"data": {"message": {"slot": "90", "parent_root": "0xaa"}}}'))
        self.assertEqual((r.returncode, r.stdout.splitlines()[-1]), (2, "RESULT: ERROR"), r.stdout + r.stderr)  # not "BLOCKED"

    def test_an_unreadable_genesis_could_not_be_checked(self):
        r = check(net=Net(genesis_body="not json"))
        self.assertEqual((r.returncode, r.stdout.splitlines()[-1]), (2, "RESULT: ERROR"), r.stdout + r.stderr)

    def test_head_before_gloas_is_blocked(self):
        r = check(net=Net(version="fulu"))
        self.assertResult(r, 4, "BLOCKED")
        self.assertIn("fulu", r.stdout)

    def test_a_cluster_with_no_proposal_yet_is_blocked(self):
        r = check(net=Net(only="a"))
        self.assertResult(r, 4, "BLOCKED")
        self.assertRegex(r.stdout, r"BLOCKED.*cluster b")

    def test_a_failure_beats_a_blocked_cluster(self):
        self.assertResult(check(net=Net(only="a", unbuilt={73})), 1, "FAIL")

    def test_the_last_block_has_no_successor_and_is_not_counted(self):
        self.assertResult(check(net=Net(head=73, unbuilt={73})), 0, "PASS")  # head 73 is cluster a's, unjudged yet

    def test_clusters_are_attributed_by_dkg_pubkey_not_by_index_arithmetic(self):
        net = Net(natives=range(0, 336), a=range(336, 424), b=range(424, 512))  # 112 per native, 88 per cluster
        self.assertResult(check(net=net), 0, "PASS")
        shuffled = Net(natives=range(100, 512), a=range(0, 64), b=range(64, 100), unbuilt={73})
        r = check(net=shuffled)  # DKG validators first in genesis, and uneven clusters
        self.assertResult(r, 1, "FAIL")
        self.assertRegex(r.stdout, r"slot 73 \(cluster a\)")

    def test_a_dkg_pubkey_missing_from_genesis_fails(self):
        net = Net()
        net.genesis = [v for v in net.genesis if v["index"] != "400"]
        r = check(net=net)
        self.assertResult(r, 1, "FAIL")
        self.assertIn("cluster a", r.stdout)


@needs_tools
class ConfigTest(unittest.TestCase):
    def failing(self, configs, service, what):
        r = check(configs=configs)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertEqual(len(fail_lines(r)), 1, r.stdout)  # one thing broken, one thing reported
        self.assertRegex(r.stdout, rf"FAIL +{service} {what}")

    def test_the_configs_a_real_run_rendered_pass(self):
        r = check(configs=REAL_CONFIGS)
        self.assertEqual((r.returncode, r.stdout.splitlines()[-1]), (0, "RESULT: PASS"), r.stdout + r.stderr)

    def test_every_check_runs_even_when_another_section_fails(self):
        r = check(net=Net(unbuilt={73}), configs={VC_B: vouch_yml("b", range(64, 128), ("300ms", "500ms"))})
        self.assertRegex(r.stdout, r"FAIL +vc-5-besu-nimbus-vouch multi-instance")
        self.assertRegex(r.stdout, r"slot 73 \(cluster a\)")
        self.assertEqual(r.stdout.splitlines()[-1], "RESULT: FAIL")

    def test_each_misconfiguration_fails_and_names_the_vouch_and_the_setting(self):
        accounts_b = range(64, 128)
        cases = {
            "an active delay that differs from the layout": ({VC_B: vouch_yml("b", accounts_b, ("300ms", "500ms"))}, VC_B, "multi-instance"),
            "a passive delay that differs from the layout": ({VC_P: vouch_yml("b", accounts_b, ("4s", "1s"))}, VC_P, "multi-instance"),
            "a passive without the multiinstance block": ({VC_P: vouch_yml("b", accounts_b)}, VC_P, "multi-instance"),
            "a single Vouch with a multiinstance block": ({VC_A: vouch_yml("a", range(64), ("1s", "1s"))}, VC_A, "multi-instance"),
            "a sixth beacon node": ({VC_A: vouch_yml("a", range(64), beacons=(1, 2, 3, 4, 5, 6))}, VC_A, "beacon nodes"),
            "a missing beacon node": ({VC_B: vouch_yml("b", accounts_b, ("250ms", "500ms"), beacons=(1, 2, 3, 4))}, VC_B, "beacon nodes"),
            "the other cluster's Dirk peers": ({VC_P: vouch_yml("a", accounts_b, ("4s", "2s"))}, VC_P, "Dirk peers"),
            "a missing Dirk peer": ({VC_A: vouch_yml("a", range(64), dirks=(1, 2))}, VC_A, "Dirk peers"),
        }
        for name, (configs, service, what) in cases.items():
            with self.subTest(name):
                self.failing(configs, service, what)

    def test_an_unreadable_config_could_not_be_checked(self):
        r = check(configs={VC_P: None})
        self.assertEqual((r.returncode, r.stdout.splitlines()[-1]), (2, "RESULT: ERROR"), r.stdout)
        self.assertIn(VC_P, r.stderr)


@needs_tools
class MetricsTest(unittest.TestCase):
    def failing(self, metrics, what):
        r = check(metrics=metrics)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertRegex(r.stdout, rf"FAIL +{what}")

    def test_each_broken_relationship_fails(self):
        cases = {
            "an active Vouch that signed nothing": ({VC_A: vouch_metrics(0, 0)}, f"{VC_A} signed 0 attestations"),
            "a passive that out-attests the active": ({VC_P: vouch_metrics(500, 0)}, f"{VC_P} yields"),
            "a passive that attests as much as the active": ({VC_P: vouch_metrics(458, 0)}, f"{VC_P} yields"),
            "an account Vouch could not find on its Dirk cluster": ({VC_A: vouch_metrics(451, 26, 63)}, f"{VC_A} manages"),
            "a passive on the wrong accounts": ({VC_P: vouch_metrics(0, 0, 0)}, f"{VC_P} manages"),
            "an active that sees the other cluster's accounts": ({VC_B: vouch_metrics(458, 28, 128)}, f"{VC_B} manages"),
            "Dirk attestations just under twice Vouch's": ({f"dirk-a-{n}": dirk_metrics(att=300, prop=29) for n in (1, 2, 3)}, "Dirk cluster a signed 900 attestations"),
            "Dirk proposals just under twice Vouch's": ({f"dirk-a-{n}": dirk_metrics(att=479, prop=17) for n in (1, 2, 3)}, "Dirk cluster a signed 51 proposals"),
            "Dirk proposals of the shared cluster under twice Vouch's": ({f"dirk-b-{n}": dirk_metrics(att=479, prop=10) for n in (1, 2, 3)}, "Dirk cluster b signed 30 proposals"),
            "Dirk attestations of the shared cluster under twice both instances'": ({f"dirk-b-{n}": dirk_metrics(att=300, prop=29) for n in (1, 2, 3)}, "Dirk cluster b signed 900 attestations"),
        }
        for name, (metrics, what) in cases.items():
            with self.subTest(name):
                self.failing(metrics, what)

    def test_the_passive_may_win_a_proposal_race(self):
        # More proposals than the active: reported, not compared. Dirk signed them all.
        r = check(metrics={VC_P: vouch_metrics(0, 30), **{f"dirk-b-{n}": dirk_metrics(att=479, prop=40) for n in (1, 2, 3)}})
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn(f"{VC_P} 30", r.stdout)

    def test_dirk_may_have_signed_more_than_vouch_reports(self):
        self.assertEqual(check(metrics={f"dirk-a-{n}": dirk_metrics(att=900, prop=90) for n in (1, 2, 3)}).returncode, 0)

    def test_two_peers_are_enough_for_the_threshold(self):
        # 2 of 3 sign each request: 451 attestations need 902, which two peers can supply alone.
        peers = {"dirk-a-1": dirk_metrics(451, 26), "dirk-a-2": dirk_metrics(451, 26), "dirk-a-3": dirk_metrics(0, 0)}
        self.assertEqual(check(metrics=peers).returncode, 0)

    def test_an_unreachable_metrics_endpoint_could_not_be_checked(self):
        r = check(drop={"dirk-b-2"})
        self.assertEqual((r.returncode, r.stdout.splitlines()[-1]), (2, "RESULT: ERROR"), r.stdout)
        self.assertIn("cannot read the metrics of dirk-b-2", r.stderr)

    def test_vouch_is_read_before_dirk(self):
        r = check()
        self.assertEqual(r.returncode, 0)
        self.assertEqual([s.startswith("vc-") for s in r.requests], [True] * 3 + [False] * 6, r.requests)

    def test_denied_requests_are_reported_not_asserted(self):
        r = check(metrics={f"dirk-a-{n}": dirk_metrics(att=479, prop=29, denied=3) for n in (1, 2, 3)})
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("Dirk denied 9 in cluster a and 0 in cluster b", r.stdout)

    def test_accounts_follow_the_cluster_sizes(self):
        net = Net(natives=range(0, 336), a=range(336, 424), b=range(424, 512))  # clusters of 88
        self.assertEqual(check(net=net).returncode, 0)
        r = check(net=net, metrics={VC_A: vouch_metrics(451, 26, 64)})  # the old size
        self.assertEqual(r.returncode, 1, r.stdout)
        uneven = Net(natives=range(100, 512), a=range(0, 64), b=range(64, 100))  # clusters of 64 and 36
        self.assertEqual(check(net=uneven).returncode, 0)

    def test_metrics_wait_until_both_clusters_have_proposed(self):
        r = check(net=Net(only="a"))
        self.assertEqual(r.returncode, 4)
        self.assertEqual(r.requests, [])  # nothing was read


class UsageTest(unittest.TestCase):
    @needs_tools
    def test_the_enclave_is_required(self):
        r = subprocess.run([BASH, str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual((r.returncode, "usage" in r.stderr), (2, True))


if __name__ == "__main__":
    unittest.main()
