# external-dns-monitor

`external-dns-monitor` is the independent Heighliner observer for the live DNS-correlation workflow. It probes the home DNS path through routed WireGuard and posts one compact **current observation** on every run. It has no alert-routing authority and never sends directly to Discord or Operational Event Ingress.

## Contract and boundary

The only production destination is:

```text
POST https://ops.wormlogic.com/webhook/leto/dns-observations
Header: X-Leto-Operations-Token
Token: /home/lightweight/vps-services/runtime/vps01/secrets/leto_ops_ingress_token
```

The envelope is contract version `1.0` with source `external-dns-resilience`, a persisted monotonic sequence, execution host/vantage, and boolean checks for both Pi-holes, the aggregate Heighliner-to-home DNS path, and fresh direct Midway recursion.

Heighliner is an **external/WireGuard vantage**. Its results prove an external transaction through its route, the reachable home path, and resolver response; they do not prove LAN DHCP resolver selection or local switching. The direct Midway check is explicitly diagnostic: correlation keeps Midway-only instability unalerted while internal client-facing evidence remains healthy.

The monitor reads the centrally materialized token only at send time. It does not encrypt, decrypt, copy, rotate, log, or own it.

## Release model

A committed source revision installs as an immutable root-owned release:

```text
/opt/wormlogic/external-dns-monitor/releases/<commit>
/opt/wormlogic/external-dns-monitor/current -> releases/<commit>
```

The project installer requires a clean exact commit and never enables the timer unless invoked with `--enable-timer`.

```bash
sudo ./services/external-dns-monitor/install.sh <40-character-commit>
sudo ./services/external-dns-monitor/install.sh <40-character-commit> --enable-timer
```

The installed unit owns only `/var/lib/wormlogic-external-dns-monitor` state. Sequence state is persisted there after a successful webhook acceptance, preserving monotonic observations across timer executions.

## Verification

```bash
cd services/external-dns-monitor
./verify.sh
sudo /opt/wormlogic/external-dns-monitor/current/verify.sh
sudo /opt/wormlogic/external-dns-monitor/current/verify.sh --diagnostic
```

`--diagnostic` performs real DNS probes and prints an envelope without posting it. It does not mutate sequence state.

## Operational status

`wormlogic-external-dns-monitor` is the authoritative Heighliner external-vantage observer for the DNS-correlation workflow. Its timer runs the immutable installed release; current observations are accepted by the DNS-correlation workflow, which alone promotes actionable transitions to the established operational-event ingress and alert-routing path.
