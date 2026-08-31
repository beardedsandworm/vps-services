#!/usr/bin/env python3
"""Emit a current DNS observation from the Heighliner WireGuard vantage."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import time
import tomllib
from urllib import request

SINKHOLE_ADDRESSES = {"0.0.0.0", "::"}
CENTRAL_TOKEN_FILE = Path("/home/lightweight/vps-services/runtime/vps01/secrets/leto_ops_ingress_token")
MACHINE_ID = "vps01"
STATE_FILE = Path("/var/lib/wormlogic-external-dns-monitor/state.json")


@dataclass(frozen=True)
class Config:
    positive_name: str
    blocked_name: str
    vantage: str
    endpoint: str
    token_file: Path
    machine_id: str
    piholes: dict[str, str]
    midway_address: str
    state_file: Path


def load_config(path: Path) -> Config:
    data = tomllib.loads(path.read_text())
    monitor = data["monitor"]
    ingress = data["ingress"]
    piholes = {name: item["address"] for name, item in data["piholes"].items()}
    if set(piholes) != {"pihole1", "pihole2"}:
        raise ValueError("configuration must define pihole1 and pihole2")
    if monitor["vantage"] != "external-wireguard":
        raise ValueError("monitor must use the external WireGuard vantage")
    if ingress["endpoint"] != "https://ops.wormlogic.com/webhook/leto/dns-observations":
        raise ValueError("ingress endpoint must be the live DNS observation webhook")
    if Path(ingress["token_file"]) != CENTRAL_TOKEN_FILE:
        raise ValueError("ingress must use the centrally materialized token path")
    if ingress["machine_id"] != MACHINE_ID:
        raise ValueError("ingress machine_id must be vps01")
    if Path(monitor.get("state_file", STATE_FILE)) != STATE_FILE:
        raise ValueError("monitor state_file must use the service state directory")
    return Config(
        positive_name=monitor["positive_name"],
        blocked_name=monitor["blocked_name"],
        vantage=monitor["vantage"],
        endpoint=ingress["endpoint"],
        token_file=CENTRAL_TOKEN_FILE,
        machine_id=MACHINE_ID,
        piholes=piholes,
        midway_address=data["midway"]["address"],
        state_file=STATE_FILE,
    )


def parse_dig(output: str, returncode: int, expected_server: str) -> dict[str, object]:
    status = re.search(r"status:\s*([A-Z]+)", output)
    latency = re.search(r"Query time:\s*(\d+)\s*msec", output)
    server = re.search(r"SERVER:\s*([^#\s]+)#", output)
    answers = []
    for line in output.splitlines():
        fields = line.split()
        if line and not line.startswith(";") and len(fields) >= 5 and fields[3] in {"A", "AAAA"}:
            answers.append(fields[4])
    return {
        "transport_ok": returncode == 0 and server is not None and server.group(1) == expected_server,
        "rcode": status.group(1) if status else None,
        "answers": answers,
        "latency_ms": int(latency.group(1)) if latency else None,
    }


def probe_dns(server: str, name: str, tcp: bool = False) -> dict[str, object]:
    command = ["/usr/bin/dig", "+time=2", "+tries=1", "+comments"]
    if tcp:
        command.append("+tcp")
    command.extend([f"@{server}", name, "A"])
    started = time.monotonic()
    try:
        completed = subprocess.run(command, text=True, capture_output=True, timeout=4, check=False)
        result = parse_dig(completed.stdout + completed.stderr, completed.returncode, server)
    except subprocess.TimeoutExpired:
        result = {"transport_ok": False, "rcode": None, "answers": [], "latency_ms": None}
    result["elapsed_ms"] = round((time.monotonic() - started) * 1000, 1)
    return result


def _functional(result: dict[str, object]) -> bool:
    return result["transport_ok"] is True and result["rcode"] == "NOERROR" and bool(result["answers"])


def _blocking(result: dict[str, object]) -> bool:
    return _functional(result) and set(result["answers"]).issubset(SINKHOLE_ADDRESSES)


def _fresh_recursion(result: dict[str, object]) -> bool:
    # A unique name can legitimately return NOERROR without an A answer; the
    # successful fresh transaction, not an address, is the diagnostic signal.
    return result["transport_ok"] is True and result["rcode"] == "NOERROR"


def collect_snapshot(config: Config, *, probe=probe_dns, observed_at: str | None = None, nonce: str | None = None) -> dict[str, object]:
    piholes = {}
    for name, address in config.piholes.items():
        udp = probe(address, config.positive_name)
        tcp = probe(address, config.positive_name, tcp=True)
        blocked = probe(address, config.blocked_name)
        piholes[name] = {
            "udp": _functional(udp),
            "tcp": _functional(tcp),
            "blocking": _blocking(blocked),
            "latency_ms": udp.get("latency_ms"),
        }
    probe_nonce = nonce or secrets.token_hex(8)
    midway = probe(config.midway_address, f"dns-resilience-{probe_nonce}.{config.positive_name}")
    return {
        "observed_at": observed_at or datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "vantage": config.vantage,
        "piholes": piholes,
        "midway": {"fresh_recursion": _fresh_recursion(midway), "latency_ms": midway.get("latency_ms")},
    }


def _check_status(result: dict[str, object]) -> str:
    if all(result.get(name) is True for name in ("udp", "tcp", "blocking")):
        return "ok"
    if any(result.get(name) is True for name in ("udp", "tcp", "blocking")):
        return "degraded"
    return "failed"


def current_observation_envelope(snapshot: dict[str, object], *, machine_id: str, revision: str, sequence: int) -> dict[str, object]:
    piholes = snapshot["piholes"]
    pihole_a = all(piholes["pihole1"][check] is True for check in ("udp", "tcp", "blocking"))
    pihole_b = all(piholes["pihole2"][check] is True for check in ("udp", "tcp", "blocking"))
    return {
        "contract_version": "1.0",
        "source": "external-dns-resilience",
        "observed_at": snapshot["observed_at"],
        "sequence": sequence,
        "execution": {"host": machine_id, "vantage": snapshot["vantage"], "runtime_revision": revision},
        "checks": {
            "external_path": pihole_a and pihole_b,
            "resolvers": {"pihole_a": pihole_a, "pihole_b": pihole_b},
            # Direct Midway evidence is diagnostic in correlation, never a
            # client-impact claim by this external observer.
            "midway_recursion": snapshot["midway"]["fresh_recursion"] is True,
        },
    }


def post_envelope(endpoint: str, token_file: Path, envelope: dict[str, object], *, timeout: int) -> None:
    token = token_file.read_text().strip()
    if not token:
        raise RuntimeError("n8n ingress token file is empty")
    body = json.dumps(envelope, sort_keys=True, separators=(",", ":")).encode()
    request_object = request.Request(
        endpoint,
        data=body,
        method="POST",
        headers={"Content-Type": "application/json", "X-Leto-Operations-Token": token},
    )
    with request.urlopen(request_object, timeout=timeout) as response:
        if not 200 <= response.status < 300:
            raise RuntimeError(f"n8n ingress returned HTTP {response.status}")


def runtime_revision() -> str:
    revision_file = Path(__file__).with_name("REVISION")
    try:
        revision = revision_file.read_text().strip()
    except OSError:
        return "development-uninstalled"
    return revision if re.fullmatch(r"[0-9a-f]{40}", revision) else "invalid-revision"


def preflight(config: Config, *, require_runtime_revision: bool = False) -> None:
    missing = []
    if not (Path("/usr/bin/dig").is_file() and os.access("/usr/bin/dig", os.X_OK)):
        missing.append("/usr/bin/dig")
    if not os.access(config.token_file, os.R_OK):
        missing.append(f"n8n ingress token file: {config.token_file}")
    if require_runtime_revision and runtime_revision() in {"development-uninstalled", "invalid-revision"}:
        missing.append("installed REVISION")
    if missing:
        raise RuntimeError("preflight failed; missing or inaccessible " + ", ".join(missing))


def _read_state(path: Path) -> dict[str, int]:
    try:
        state = json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}
    return state if isinstance(state, dict) else {}


def _write_state(path: Path, sequence: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps({"last_sequence": sequence}, sort_keys=True) + "\n")
    temporary.replace(path)


def run_once(config: Config, *, revision: str, collect=collect_snapshot, post=post_envelope) -> dict[str, object]:
    sequence = int(_read_state(config.state_file).get("last_sequence", 0)) + 1
    envelope = current_observation_envelope(collect(config), machine_id=config.machine_id, revision=revision, sequence=sequence)
    post(config.endpoint, config.token_file, envelope, timeout=10)
    _write_state(config.state_file, sequence)
    return envelope


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--preflight", action="store_true")
    parser.add_argument("--require-runtime-revision", action="store_true")
    parser.add_argument("--diagnostic", action="store_true", help="collect and print without posting")
    args = parser.parse_args(argv)
    config = load_config(args.config)
    if args.preflight:
        preflight(config, require_runtime_revision=args.require_runtime_revision)
        print("external-dns-monitor preflight: ok")
        return 0
    snapshot = collect_snapshot(config)
    sequence = int(_read_state(config.state_file).get("last_sequence", 0)) + 1
    envelope = current_observation_envelope(snapshot, machine_id=config.machine_id, revision=runtime_revision(), sequence=sequence)
    if args.diagnostic:
        print(json.dumps(envelope, sort_keys=True))
    else:
        post_envelope(config.endpoint, config.token_file, envelope, timeout=10)
        _write_state(config.state_file, sequence)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"external-dns-monitor: {exc}", file=sys.stderr)
        raise SystemExit(2)
