# Local resolution for ops.wormlogic.com

Heighliner hosts the `ops.wormlogic.com` Caddy/n8n service locally. The hostname intentionally has no public DNS record, so Heighliner maintains this root-managed `/etc/hosts` entry:

```text
127.0.0.1 ops.wormlogic.com
```

This is a delivery-path dependency for local services such as `external-dns-monitor` reaching the authenticated n8n ingress over normal HTTPS/SNI. It does not alter the monitor's external WireGuard probes of the home DNS site. Preserve this mapping during host recovery before activating the `wormlogic-external-dns-monitor` service.
