# PVP DNS

DNS filtering and encrypted Internet egress for the Heighliner PVP gateway.

## What is PVP?

Within Wormlogic, **PVP** means operating on an **unknown or untrusted network**.

The name comes from early MMO PvP servers: environments where other participants could not automatically be trusted. The same principle applies here—public Wi-Fi, hotels, airports, guest networks, unfamiliar wired networks, or any network not explicitly marked trusted is treated as potentially hostile.

PVP is therefore a **network trust state**, not a location or VPN provider.

When enabled, a client tunnels to Heighliner and receives Wormlogic-managed DNS filtering while Internet traffic exits through Proton VPN.

```text
                     ┌─ Wormlogic private networks → wg0
PVP client → wg-pvp ─┤
                     ├─ DNS → Pi-hole → Unbound → Quad9 DoT → wg-proton
                     └─ Internet ────────────────────────────→ wg-proton
```

PVP traffic is intended to fail closed rather than fall back to Heighliner's normal `eth0` Internet connection.

## DNS

Pi-hole is the client-facing resolver. It forwards to native Unbound at:

```text
172.21.0.1:5335
```

Unbound accepts requests from the Pi-hole container (`172.21.0.2`) and forwards allowed queries exclusively over DNS-over-TLS to Quad9:

```text
9.9.9.9:853
149.112.112.112:853
```

Unbound uses:

```text
module-config: "python iterator"
```

The Python module performs DNSBL filtering against:

```text
/var/lib/unbound/pvp-dnsbl.sqlite
```

SQLite is used instead of loading the roughly 2.3 million policy records directly into Unbound memory.

Quad9 performs upstream DNSSEC validation, so a separate Unbound validator is intentionally not used.

## Filtering policy

The policy mirrors Midway/OPNsense.

**Security**

* HaGeZi Threat Intelligence
* HaGeZi Fake/scams

**Adblocking**

* EasyList
* EasyPrivacy
* OISD Small

**DNS enforcement**

* HaGeZi DoH/VPN/TOR/Proxy Bypass

These are the six required sources. The discontinued ThreatFox (`atf`) feed is
not part of the policy; its endpoint now returns HTTP 410.

The DNS-enforcement policy retains the Midway Tor Project allowlist:

```text
www.torproject.org
dist.torproject.org
aus1.torproject.org
static.torproject.org
```

Blocked A/CNAME queries return `0.0.0.0`, matching Midway behavior rather than returning `NXDOMAIN`.

## Automatic updates

`wormlogic-pvp-dns-update.timer` refreshes the blocklists daily.

The associated oneshot service:

1. verifies/restores required host state
2. refreshes all six sources independently
3. rejects empty downloads and retains a per-source last-known-good copy under `/var/cache/wormlogic-pvp-dns/`
4. warns when a fallback cache is at least seven days old
5. refuses to replace the production database if a required source has neither a valid download nor a cached copy
6. builds a temporary SQLite database while preserving the existing policy IDs, allowlists, wildcard semantics and schema
7. rejects empty policies and requires `PRAGMA integrity_check` to return `ok`
8. replaces the production database atomically only after all validation succeeds
9. validates the Unbound configuration and restarts Unbound only after a successful build

`Persistent=true` causes a missed refresh to run after downtime.

A successful oneshot service normally appears as `inactive (dead)` after completion.

The service drop-in invokes the builder through `/usr/bin/python3` explicitly.
Do not restore direct execution of the script: the explicit interpreter avoids
systemd `203/EXEC` failures and is part of the deployed contract.

## Systemd dependency architecture

The installer owns the complete Unbound administrator unit at
`/etc/systemd/system/unbound.service`, along with its drop-ins. The full unit is
based on Ubuntu's vendor definition but deliberately omits:

```ini
Before=nss-lookup.target
Wants=nss-lookup.target
```

Those vendor edges formed boot-ordering cycles among WireGuard, Docker, PVP
policy routing and DNS initialization. The retained dependency graph is:

```text
network-online.target
        ↓
wg-proton
        ↓
wormlogic-pvp-dns-update.service
        ↓
unbound.service
```

`unbound.service.d/override.conf` waits for the already-created Pi-hole bridge
address without adding an Unbound `Requires=` or `After=` dependency on Docker.
`unbound.service.d/wormlogic-pvp.conf` retains the required `wg-proton` and PVP
DNS update relationships. Docker continues to depend on `wg-pvp` for Pi-hole's
published address, independently of Unbound.

Because the administrator unit shadows the package unit, future Unbound package
updates do not automatically update this copy. Review every vendor unit change
against `services/pvp-dns/unbound.service`, preserve relevant service-definition
changes, and continue excluding the two `nss-lookup.target` edges unless the
dependency architecture is deliberately redesigned and reboot-tested.

## Host requirements

### Policy routing

Locally generated Unbound traffic must use the PVP routing table:

```text
priority 110
uidrange <unbound UID>-<unbound UID>
lookup pvp
```

A successful route check resembles:

```text
9.9.9.9 dev wg-proton table pvp src 10.2.0.2 uid 111
```

The PVP gateway owns the routing table itself; this service only restores the Unbound selector and verifies that the table routes through `wg-proton`.

### AppArmor

Ubuntu's Unbound AppArmor profile requires additional access for the Python module and SQLite database:

```text
/usr/local/lib/wormlogic-pvp-dns/
/usr/local/lib/wormlogic-pvp-dns/**
/var/lib/unbound/pvp-dnsbl.sqlite
```

The SQLite file requires `rk` permission because SQLite requests a file lock even when used read-only.

`install.sh` manages these permissions through the local Unbound AppArmor override.

### GRO workaround

Generic Receive Offload must currently be disabled on Heighliner's `eth0`:

```bash
ethtool -K eth0 gro off
```

With GRO enabled, incoming encrypted Proton WireGuard packets were observed reaching `eth0` but intermittently failing to emerge from `wg-proton`, causing TLS connections to stall. Disabling GRO restored reliable HTTPS and Quad9 DoT traffic.

`ensure-host-state.sh` restores and verifies this setting automatically.

No special WireGuard MTU override is required.

## Installation

From the `vps-services` repository:

```bash
./services/pvp-dns/install.sh
```

The installer handles:

* Unbound and Python support
* DNSBL module and database builder
* initial blocklist build
* AppArmor permissions
* GRO workaround
* Unbound UID policy routing
* full Unbound administrator unit and PVP DNS drop-ins
* update service, explicit-Python override and timer
* Unbound validation and restart

The PVP WireGuard gateway and `wg-proton` must already be available.

## Verification

```bash
systemctl is-active unbound
systemctl status wormlogic-pvp-dns-update.timer --no-pager

ethtool -k eth0 | grep generic-receive-offload
ip rule | grep '110:'
ip route get 9.9.9.9 uid "$(id -u unbound)"
```

Test DNS from Pi-hole's network namespace:

```bash
PIHOLE_PID="$(docker inspect -f '{{.State.Pid}}' pihole)"

sudo nsenter -t "$PIHOLE_PID" -n \
  dig @172.21.0.1 -p 5335 example.com A +short

sudo nsenter -t "$PIHOLE_PID" -n \
  dig @172.21.0.1 -p 5335 torproject.org A +short

sudo nsenter -t "$PIHOLE_PID" -n \
  dig @172.21.0.1 -p 5335 www.torproject.org A +short
```

Expected:

```text
example.com          → public IPs
torproject.org       → 0.0.0.0
www.torproject.org   → public IPs
```

Direct Quad9 DoT can be checked with:

```bash
sudo -u unbound openssl s_client \
  -connect 9.9.9.9:853 \
  -servername dns.quad9.net \
  -brief </dev/null
```

## Ownership and recovery

This directory owns the **PVP DNS subsystem** and the host state required for it.

It does not own:

* WireGuard or Proton secret material
* the authoritative PVP routing table
* the PVP nftables kill switch
* unrelated Heighliner host configuration

Secrets remain under the normal `vps-services` SOPS/age recovery workflow.

Recovery order:

```text
clone vps-services
→ recover secrets
→ restore/start PVP WireGuard gateway
→ services/pvp-dns/install.sh
→ Pi-hole → Unbound → Quad9 DoT → Proton operational
```

The current PVP nftables configuration is intentionally outside this DNS persistence work and should be recaptured once the gateway firewall configuration is finalized.
