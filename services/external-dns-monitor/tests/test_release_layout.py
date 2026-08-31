import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]


class ReleaseLayoutTests(unittest.TestCase):
    def test_self_contained_release_has_immutable_installer_and_timer(self):
        required = {
            "external_dns_monitor.py",
            "external-dns-monitor.toml.example",
            "install.sh",
            "verify.sh",
            "wormlogic-external-dns-monitor.service",
            "wormlogic-external-dns-monitor.timer",
            "README.md",
        }
        self.assertTrue(required.issubset({path.name for path in ROOT.iterdir()}))
        installer = (ROOT / "install.sh").read_text()
        self.assertIn('git -C "$repo_root" archive --format=tar', installer)
        self.assertIn("releases", installer)
        self.assertIn("action=none", installer)
        unit = (ROOT / "wormlogic-external-dns-monitor.service").read_text()
        self.assertIn("leto_ops_ingress_token", unit)
        self.assertIn("--require-runtime-revision", unit)
        verifier = (ROOT / "verify.sh").read_text()
        self.assertIn("--source", verifier)
        timer = (ROOT / "wormlogic-external-dns-monitor.timer").read_text()
        self.assertIn("OnUnitInactiveSec", timer)


if __name__ == "__main__":
    unittest.main()
