import importlib.util
import json
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MODULE = Path(__file__).parents[1] / "external_dns_monitor.py"
spec = importlib.util.spec_from_file_location("external_dns_monitor", MODULE)
monitor = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = monitor
spec.loader.exec_module(monitor)


class ObservationEnvelopeTests(unittest.TestCase):
    def test_current_envelope_is_compact_deterministic_and_secret_free(self):
        snapshot = {
            "observed_at": "2026-08-30T19:30:00Z",
            "vantage": "external-wireguard",
            "piholes": {
                "pihole1": {"udp": True, "tcp": True, "blocking": True, "latency_ms": 12},
                "pihole2": {"udp": True, "tcp": False, "blocking": False, "latency_ms": None},
            },
            "midway": {"fresh_recursion": True, "latency_ms": 9},
        }
        envelope = monitor.current_observation_envelope(snapshot, machine_id="vps01", revision="a" * 40, sequence=7)
        self.assertEqual(envelope, {
            "contract_version": "1.0",
            "source": "external-dns-resilience",
            "observed_at": "2026-08-30T19:30:00Z",
            "sequence": 7,
            "execution": {"host": "vps01", "vantage": "external-wireguard", "runtime_revision": "a" * 40},
            "checks": {
                "external_path": False,
                "resolvers": {"pihole_a": True, "pihole_b": False},
                "midway_recursion": True,
            },
        })
        self.assertNotIn("token", repr(envelope).lower())


class ConfigurationTests(unittest.TestCase):
    def test_config_requires_external_vantage_and_runtime_token_file(self):
        config_text = """[monitor]
positive_name = "example.com"
blocked_name = "doubleclick.net"
vantage = "external-wireguard"

[ingress]
endpoint = "https://ops.wormlogic.com/webhook/leto/dns-observations"
token_file = "/home/lightweight/vps-services/runtime/vps01/secrets/leto_ops_ingress_token"
machine_id = "vps01"

[piholes.pihole1]
address = "10.42.42.10"
[piholes.pihole2]
address = "10.42.42.11"
[midway]
address = "10.42.42.1"
"""
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "monitor.toml"
            path.write_text(config_text)
            config = monitor.load_config(path)
        self.assertEqual(config.vantage, "external-wireguard")
        self.assertEqual(config.endpoint, "https://ops.wormlogic.com/webhook/leto/dns-observations")
        self.assertEqual(str(config.token_file), "/home/lightweight/vps-services/runtime/vps01/secrets/leto_ops_ingress_token")
        self.assertEqual(config.piholes["pihole1"], "10.42.42.10")
        self.assertEqual(config.midway_address, "10.42.42.1")

    def test_config_rejects_a_noncentral_token_path(self):
        config_text = """[monitor]
positive_name = "example.com"
blocked_name = "doubleclick.net"
vantage = "external-wireguard"

[ingress]
endpoint = "https://ops.wormlogic.com/webhook/leto/dns-observations"
token_file = "/tmp/alternate-token"
machine_id = "vps01"

[piholes.pihole1]
address = "10.42.42.10"
[piholes.pihole2]
address = "10.42.42.11"
[midway]
address = "10.42.42.1"
"""
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "monitor.toml"
            path.write_text(config_text)
            with self.assertRaisesRegex(ValueError, "centrally materialized token"):
                monitor.load_config(path)


class ProbeTests(unittest.TestCase):
    def test_collect_snapshot_probes_both_piholes_and_nonce_midway_query(self):
        config = monitor.Config("example.com", "doubleclick.net", "external-wireguard", "https://ops.example", Path("/token"), "vps01", {"pihole1": "10.42.42.10", "pihole2": "10.42.42.11"}, "10.42.42.1", Path("/state.json"))
        calls = []
        def probe(server, name, tcp=False):
            calls.append((server, name, tcp))
            return {"transport_ok": True, "rcode": "NOERROR", "answers": ["203.0.113.1"], "latency_ms": 7}
        snapshot = monitor.collect_snapshot(config, probe=probe, observed_at="2026-08-30T19:30:00Z", nonce="abc123")
        self.assertEqual(snapshot["piholes"]["pihole1"], {"udp": True, "tcp": True, "blocking": False, "latency_ms": 7})
        self.assertEqual(snapshot["piholes"]["pihole2"], {"udp": True, "tcp": True, "blocking": False, "latency_ms": 7})
        self.assertEqual(snapshot["midway"], {"fresh_recursion": True, "latency_ms": 7})
        self.assertIn(("10.42.42.1", "dns-resilience-abc123.example.com", False), calls)
        self.assertEqual(len(calls), 7)

    def test_midway_noerror_without_an_answer_is_fresh_recursion(self):
        config = monitor.Config("example.com", "doubleclick.net", "external-wireguard", "https://ops.example", Path("/token"), "vps01", {"pihole1": "10.42.42.10", "pihole2": "10.42.42.11"}, "10.42.42.1", Path("/state.json"))

        def probe(server, _name, tcp=False):
            if server == "10.42.42.1":
                return {"transport_ok": True, "rcode": "NOERROR", "answers": [], "latency_ms": 7}
            return {"transport_ok": True, "rcode": "NOERROR", "answers": ["203.0.113.1"], "latency_ms": 7}

        snapshot = monitor.collect_snapshot(config, probe=probe, observed_at="2026-08-30T19:30:00Z", nonce="abc123")
        self.assertTrue(snapshot["midway"]["fresh_recursion"])


class IngressTests(unittest.TestCase):
    def test_post_envelope_authenticates_with_token_header_only(self):
        received = {}

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                received["path"] = self.path
                received["token"] = self.headers.get("X-Leto-Operations-Token")
                received["body"] = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                self.send_response(204)
                self.end_headers()
            def log_message(self, *_args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as temporary:
                token_file = Path(temporary) / "token"
                token_file.write_text("not-in-the-envelope\n")
                monitor.post_envelope(
                    f"http://127.0.0.1:{server.server_port}/webhook/leto/dns-observations",
                    token_file,
                    {"contract_version": "1.0", "source": "external-dns-resilience"},
                    timeout=2,
                )
        finally:
            server.shutdown()
            thread.join()
            server.server_close()
        self.assertEqual(received["path"], "/webhook/leto/dns-observations")
        self.assertEqual(received["token"], "not-in-the-envelope")
        self.assertEqual(received["body"], {"contract_version": "1.0", "source": "external-dns-resilience"})

    def test_run_once_persists_monotonic_sequence_after_accepted_posts(self):
        with tempfile.TemporaryDirectory() as temporary:
            state_file = Path(temporary) / "state.json"
            config = monitor.Config("example.com", "doubleclick.net", "external-wireguard", "https://ops.example", Path("/token"), "vps01", {"pihole1": "one", "pihole2": "two"}, "midway", state_file)
            snapshot = {"observed_at": "2026-08-30T19:30:00Z", "vantage": config.vantage, "piholes": {"pihole1": {"udp": True, "tcp": True, "blocking": True}, "pihole2": {"udp": False, "tcp": False, "blocking": False}}, "midway": {"fresh_recursion": True}}
            sent = []
            first = monitor.run_once(config, revision="b" * 40, collect=lambda _: snapshot, post=lambda endpoint, token, body, timeout: sent.append((endpoint, token, body, timeout)))
            second = monitor.run_once(config, revision="b" * 40, collect=lambda _: snapshot, post=lambda endpoint, token, body, timeout: sent.append((endpoint, token, body, timeout)))
        self.assertEqual(first["checks"], {"external_path": False, "resolvers": {"pihole_a": True, "pihole_b": False}, "midway_recursion": True})
        self.assertEqual([item[2]["sequence"] for item in sent], [1, 2])
        self.assertEqual(second["source"], "external-dns-resilience")


if __name__ == "__main__":
    unittest.main()
