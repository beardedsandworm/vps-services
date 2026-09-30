# 🪱 Wormlogic VPS Services

**Host:** Heighliner (`vps01`, runtime hostname `wormlogic-vps01`)
**Repository:** `beardedsandworm/vps-services`

This repository owns Heighliner's Docker service definitions, versioned application configuration, encrypted service-secret sources and the service-specific monitoring components listed below. Host bootstrap and the current WireGuard peer/topology definitions live in `linux-environments`.

---

## 🧠 Philosophy

Wormlogic infrastructure is built around a few core principles:

- 🔁 **Reproducible** — rebuild everything from scratch with minimal steps
- 🔐 **Private-first** — internal services are never exposed directly
- 🧩 **Composable** — clean separation between host, VPN, and services
- 📡 **Remote-native** — full LAN access from anywhere

## Topology and ownership

```text
administrative clients
  → Heighliner / WireGuard hub (10.8.0.1)
  → Midway (10.8.0.2)
  → segmented home VLANs
```

Arrakis (`server01`, `10.8.0.3`) and IX (`server02`, `10.8.0.4`) are host peers. Midway is the home router/gateway. Home-network addressing is documented in `linux-environments/docs/NETWORK.md`.

Heighliner also hosts the PVP VPN network at `10.9.0.1`. That DNS/client path is distinct from the home Pi-hole/Unbound path.

## Compose stack

The authoritative manifest is **`compose.yaml`**. Use the repository's `dc` wrapper: it anchors the project directory and loads `env/vps01.env`.

| Service | Purpose / exposure |
|---|---|
| `caddy` | Built from the repository's Caddy image definition; publishes HTTP/HTTPS ports |
| `n8n` | Operations automation; on internal Compose networks, reached through Caddy |
| `postgres` | Application database; no direct host port binding |
| `beszel` | Monitoring hub; no direct host port binding |
| `pihole` | VPS/PVP DNS; DNS binds `127.0.0.1:1053` and `10.9.0.1:53`; UI binds those addresses on port 8081 |
| `homepage-docker-proxy` | Homepage Docker visibility on `10.8.0.1:2375` |

The Docker proxy disables POST and other unnecessary endpoints, but allowed container inspection can return environment values, including credentials. Treat its network access as sensitive; a read-only proxy is not a secret-safe interface.

## Repository layout

```text
vps-services/
├── compose.yaml
├── Dockerfile.caddy
├── dc
├── caddy
├── env/vps01.env.example
├── config/
│   ├── caddy/Caddyfile
│   ├── caddy/{data,config}/
│   ├── beszel/data/
│   └── postgres/
├── secrets/vps01/*.enc
├── scripts/
│   ├── decrypt-secrets.sh
│   ├── install.sh
│   ├── deploy.sh
│   └── status.sh
├── services/
│   ├── external-dns-monitor/
│   └── pvp-dns/
├── n8n/leto-operations/
├── docs/OPS_LOCAL_RESOLUTION.md
├── systemd/wormlogic-wireguard-forwarding.service
└── wireguard/wg0.conf.example
```

Runtime service state and decrypted secrets are separate from tracked deployment inputs.

## Secrets and machine identity

Encrypted service sources are under `secrets/vps01/`:

- `caddy.env.enc`;
- `n8n.env.enc`;
- `postgres.env.enc`;
- `pihole_web_password.txt.enc`;
- `leto_ops_ingress_token.enc`.

`scripts/decrypt-secrets.sh` materializes these files into `runtime/vps01/secrets/`, setting the directory to 0700 and files to 0600. Existing runtime secret files are overwritten. Never print decrypted contents or put plaintext credentials into the repository.

## Operating and validation interfaces

On an already provisioned host, with `env/vps01.env` and materialized secrets in place, these checks are read-only:

```sh
cd /home/lightweight/vps-services
./dc config --quiet
./dc config --services
./dc ps
git status --short
```

The `caddy` helper provides `validate` and `reload`; `reload` applies changes to the running service. Do not use a raw environment or complete interpolated Compose dump as a diagnostic when checking only secret presence or service names.

Legacy scripts:

- `scripts/install.sh` expects plaintext `secrets/wg0.conf`, installs/starts WireGuard and a forwarding unit, then invokes bare `docker compose up -d`.
- `scripts/deploy.sh` installs that plaintext WireGuard file, restarts `wg-quick@wg0` and invokes bare Compose.

## Monitoring and automation

- [`services/external-dns-monitor/README.md`](services/external-dns-monitor/README.md) owns the external DNS monitor's installation, immutable-release and verification contract.
- [`services/pvp-dns/README.md`](services/pvp-dns/README.md) describes the VPS/PVP DNS component.
- [`n8n/leto-operations/README.md`](n8n/leto-operations/README.md) describes the versioned operations workflow material.
- Beszel runs as a Compose service; Beszel Agent runs separately on the host.

Heighliner serves `ops.wormlogic.com` locally. Preserve the local-resolution requirement in [`docs/OPS_LOCAL_RESOLUTION.md`](docs/OPS_LOCAL_RESOLUTION.md) during recovery.
