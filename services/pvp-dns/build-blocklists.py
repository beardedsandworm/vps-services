
#!/usr/bin/env python3

import ipaddress
import os
import re
import sqlite3
import sys
import time
import urllib.request
from pathlib import Path

DB_PATH = Path("/var/lib/unbound/pvp-dnsbl.sqlite")
CACHE_DIR = Path("/var/cache/wormlogic-pvp-dns")
STALE_DAYS = 7

POLICIES = {
    1: {
        "name": "Security",
        "sources": {
            "hgz011": "https://hagezi-mirror.dnsbunker.org/wildcard/tif.txt",
            "hgz009": "https://hagezi-mirror.dnsbunker.org/wildcard/fake.txt",
        },
        "allowlist": [],
    },
    2: {
        "name": "Adblocking",
        "sources": {
            "el": "https://v.firebog.net/hosts/Easylist.txt",
            "ep": "https://v.firebog.net/hosts/Easyprivacy.txt",
            "oisd0": "https://small.oisd.nl/domainswild",
        },
        "allowlist": [],
    },
    3: {
        "name": "DNS Enforcement",
        "sources": {
            "hgz014": "https://hagezi-mirror.dnsbunker.org/wildcard/doh-vpn-proxy-bypass.txt",
        },
        "allowlist": [
            "www.torproject.org",
            "dist.torproject.org",
            "aus1.torproject.org",
            "static.torproject.org",
        ],
    },
}

DOMAIN_RE = re.compile(
    r"^(?:[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?\.)+"
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$",
    re.I,
)


def log(message):
    print(message, file=sys.stderr, flush=True)


def normalize(raw):
    raw = raw.split("#", 1)[0].strip()
    if not raw:
        return None

    fields = raw.split()

    try:
        ipaddress.ip_address(fields[0])
        if len(fields) < 2:
            return None
        raw = fields[-1]
    except ValueError:
        raw = fields[-1]

    raw = raw.lower().rstrip(".")

    wildcard = 0
    if raw.startswith("*."):
        wildcard = 1
        raw = raw[2:]

    try:
        ipaddress.ip_address(raw)
        return None
    except ValueError:
        pass

    if not DOMAIN_RE.fullmatch(raw):
        return None

    return raw, wildcard


def fetch_source(shortcode, url):
    cache = CACHE_DIR / f"{shortcode}.txt"
    tmp = CACHE_DIR / f"{shortcode}.txt.new"

    tmp.unlink(missing_ok=True)

    try:
        req = urllib.request.Request(
            url,
            headers={
                "User-Agent": "wormlogic-pvp-dns/2.0"
            },
        )

        count = 0

        with urllib.request.urlopen(
            req, timeout=60
        ) as response, tmp.open("w", encoding="utf-8") as output:

            for raw in response:
                item = normalize(
                    raw.decode("utf-8", errors="replace")
                )

                if item is None:
                    continue

                domain, wildcard = item
                output.write(
                    f"{'*.' if wildcard else ''}{domain}\n"
                )
                count += 1

            output.flush()
            os.fsync(output.fileno())

        if count == 0:
            raise ValueError("No valid domains downloaded")

        tmp.chmod(0o600)
        tmp.replace(cache)

        log(f"OK: {shortcode}: downloaded {count:,} entries")
        return cache, True

    except Exception as exc:
        tmp.unlink(missing_ok=True)

        log(f"WARNING: {shortcode}: {exc}")
        log(f"WARNING: Source URL: {url}")

        if not cache.is_file() or cache.stat().st_size == 0:
            log(f"ERROR: {shortcode}: no cached copy available")
            return None, False

        age = (time.time() - cache.stat().st_mtime) / 86400

        log(
            f"WARNING: {shortcode}: using cached copy "
            f"({age:.1f} days old)"
        )

        if age >= STALE_DAYS:
            log(
                f"WARNING: {shortcode}: cache exceeds "
                f"{STALE_DAYS}-day freshness threshold"
            )

        return cache, False


def main():
    CACHE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)

    sources = {}
    unavailable = []
    cached = []

    # Refresh every source independently.
    for policy in POLICIES.values():
        for shortcode, url in policy["sources"].items():
            if shortcode in sources:
                continue

            path, fresh = fetch_source(shortcode, url)
            sources[shortcode] = path

            if path is None:
                unavailable.append(shortcode)
            elif not fresh:
                cached.append(shortcode)

    # Never publish an incomplete database.
    if unavailable:
        log(
            "ERROR: Missing required sources: "
            + ", ".join(unavailable)
        )
        log("Existing production database preserved")
        return 1

    tmp = Path(str(DB_PATH) + ".new")
    tmp.unlink(missing_ok=True)

    db = None

    try:
        db = sqlite3.connect(tmp)

        db.executescript(
            """
            PRAGMA journal_mode=OFF;
            PRAGMA synchronous=FULL;
            PRAGMA temp_store=FILE;

            CREATE TABLE domains (
                domain   TEXT NOT NULL,
                policy   INTEGER NOT NULL,
                wildcard INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (domain, policy)
            ) WITHOUT ROWID;

            CREATE TABLE allowlist (
                policy INTEGER NOT NULL,
                domain TEXT NOT NULL,
                PRIMARY KEY (policy, domain)
            ) WITHOUT ROWID;
            """
        )

        insert_domain = """
            INSERT INTO domains(domain, policy, wildcard)
            VALUES (?, ?, ?)
            ON CONFLICT(domain, policy)
            DO UPDATE SET wildcard =
                MAX(wildcard, excluded.wildcard)
        """

        for policy_id, policy in POLICIES.items():

            for domain in policy["allowlist"]:
                db.execute(
                    """
                    INSERT OR IGNORE INTO allowlist(policy, domain)
                    VALUES (?, ?)
                    """,
                    (policy_id, domain.lower()),
                )

            for shortcode in policy["sources"]:
                count = 0
                wildcard_count = 0
                batch = []

                with sources[shortcode].open(
                    encoding="utf-8"
                ) as source:

                    for line in source:
                        item = normalize(line)
                        if item is None:
                            continue

                        domain, wildcard = item

                        batch.append(
                            (domain, policy_id, wildcard)
                        )

                        count += 1
                        wildcard_count += wildcard

                        if len(batch) >= 5000:
                            db.executemany(insert_domain, batch)
                            db.commit()
                            batch.clear()

                if batch:
                    db.executemany(insert_domain, batch)
                    db.commit()

                if count == 0:
                    raise ValueError(
                        f"{shortcode}: empty normalized source"
                    )

                log(
                    f"{policy['name']:16} {shortcode:8} "
                    f"entries={count:8} "
                    f"wildcard={wildcard_count:8}"
                )

        db.execute("ANALYZE")
        db.commit()

        total = db.execute(
            "SELECT count(*) FROM domains"
        ).fetchone()[0]

        if total == 0:
            raise ValueError("Compiled database is empty")

        for policy_id in POLICIES:
            count = db.execute(
                "SELECT count(*) FROM domains WHERE policy = ?",
                (policy_id,),
            ).fetchone()[0]

            if count == 0:
                raise ValueError(
                    f"Policy {policy_id} contains no domains"
                )

        integrity = db.execute(
            "PRAGMA integrity_check"
        ).fetchall()

        if integrity != [("ok",)]:
            raise RuntimeError(
                f"Database integrity check failed: {integrity}"
            )

        db.close()
        db = None

        tmp.chmod(0o644)
        tmp.replace(DB_PATH)

        log(f"SUCCESS: compiled {total:,} policy/domain rows")

        if cached:
            log(
                "WARNING: Published using cached sources: "
                + ", ".join(cached)
            )
        else:
            log("SUCCESS: All sources refreshed")

        return 0

    except Exception as exc:
        log(f"ERROR: Database compilation failed: {exc}")
        log("Existing production database preserved")
        return 1

    finally:
        if db is not None:
            db.close()

        tmp.unlink(missing_ok=True)


if __name__ == "__main__":
    sys.exit(main())
