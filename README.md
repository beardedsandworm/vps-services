# 🪱 Wormlogic VPS Services

> Reproducible, private-first, composable, and observable services for **Heighliner**.

---

## 💡 Philosophy

> **Public infrastructure should be rebuildable, inspectable, minimally exposed, and recoverable without depending on memory.**

`vps-services` is the application deployment layer for **Heighliner** (`vps01`).

It owns:

* 🚀 **VPS-hosted application services**
* 🌐 **Caddy routing and public TLS**
* 🔐 **SOPS-encrypted service secrets**
* 🧩 **Versioned service configuration**
* ⚙️ **Repo-owned deployment automation**
* 🛡️ **PVP DNS application integration**
* 📊 **Service monitoring and image checks**
* 🔔 **External DNS health monitoring**
* 🔑 **Repository-specific GitHub authentication**

Four principles guide the repository:

* 🔁 **Reproducible** — deployment comes from known configuration
* 🔒 **Private-first** — expose only what needs to be public
* 🧩 **Composable** — host configuration and application deployment remain separate
* 🌍 **Remote-native** — recovery must work when the machine is physically inaccessible

---

## ⚡ Mental Model

```text
Host ready
    ↓
Recover service secrets + Compose environment
    ↓
Validate recovered configuration
    ↓
Verify required WireGuard prerequisites
    ↓
Build required images
    ↓
Reconcile containers
    ↓
Verify br-pihole exists
    ↓
Install / reconcile PVP DNS + Unbound
    ↓
Install monitoring
    ↓
Observe continuously
```

Operationally:

```text
Define → Decrypt → Validate → Deploy → Verify → Observe → Correct → Recover
```

* **Define** → Compose, Caddy, DNS and service configuration
* **Decrypt** → SOPS-encrypted runtime secrets and the recoverable Compose environment
* **Validate** → confirm recovered files, Compose rendering and required host networking
* **Deploy** → Docker Compose first where container-created network state is a prerequisite, then repo-owned installers
* **Verify** → prove the Pi-hole bridge, Unbound routing and real DNS resolution
* **Observe** → timers, health checks and external monitoring
* **Correct** → update Git when desired state changes
* **Recover** → rebuild from repo + encrypted state + mutable-state backups

---

# 🖥️ Host

`vps-services` runs on:

| Host | ID | OS | Role |
| --- | --- | --- | --- |
| 🚀 Heighliner | `vps01` | Ubuntu | Public VPS / network edge / operations host |

Host bootstrap and machine-level prerequisites are owned by:

```text
linux-environments
```

That includes:

* base OS configuration
* packages and Docker
* machine identity
* SSH identity
* age identity
* WireGuard interface definitions and recovery
* policy-routing tables
* nftables / sysctl
* base host networking and boot prerequisites

`vps-services` begins where those host prerequisites end.

Repo-owned services may install their own systemd units and service-specific ordering drop-ins, but they consume the WireGuard interfaces and routing state established by `linux-environments`; they do not redefine those host facilities.

---

# 🧩 Repository Structure

```text
vps-services/
├── .sops.yaml
├── compose.yaml
├── deploy.sh
├── dc
├── caddy
│
├── config/
│   ├── caddy/
│   ├── pihole/
│   ├── postgres/
│   ├── n8n/
│   ├── beszel/
│   └── ...
│
├── env/
│   ├── vps01.env
│   └── vps01.env.example
│
├── scripts/
│   ├── decrypt-secrets.sh
│   ├── image-check.sh
│   └── ...
│
├── services/
│   ├── pvp-dns/
│   └── external-dns-monitor/
│
├── secrets/
│   └── vps01/
│       ├── *.enc
│       └── env/
│           └── vps01.env.enc
│
├── runtime/
│   └── vps01/
│       ├── secrets/
│       └── ...
│
└── systemd/
    ├── vps-services-image-check.service
    ├── vps-services-image-check.timer
    └── ...
```

Generated runtime state belongs under `runtime/`, `/opt/wormlogic/`, or the owning application's data path.

It is not Git authority.

---

# 🧱 Repository Boundary

## ✅ Versioned Here

`vps-services` owns the desired state of services running on Heighliner.

That includes:

* `compose.yaml`
* Caddy build and routing configuration
* Pi-hole application configuration
* n8n / PostgreSQL service definitions
* monitoring integration
* PVP DNS and Unbound service configuration
* PVP DNS update/reconciliation units
* service-specific systemd ordering needed by repo-owned workloads
* external DNS monitor integration
* deployment scripts
* systemd units associated with repo-owned services
* SOPS-encrypted service secrets
* deterministic Compose-environment recovery
* environment examples and non-secret deployment metadata

---

## 🖥️ Host State Lives Elsewhere

The WireGuard authority belongs to `linux-environments`, including:

```text
/etc/wireguard/wg0.conf
/etc/wireguard/wg-pvp.conf
/etc/wireguard/wg-proton.conf
```

as well as:

* WireGuard interface creation and identity recovery
* forwarding configuration
* policy-routing tables
* nftables rules
* sysctl configuration
* machine SSH credentials
* host age recovery identity
* base host networking prerequisites

`vps-services` may **start, require and validate** those already-defined interfaces when reconciling its own services.

The boundary is:

```text
linux-environments
        ↓
provide wg0 / wg-pvp / wg-proton + routing primitives

vps-services
        ↓
provide Pi-hole / PVP DNS / Unbound / Caddy / application behavior
```

Service-specific units and ordering that exist solely to make `vps-services` workloads operate correctly remain with `vps-services`.

---

## 🗄️ Mutable Runtime State

Git does not replace backups.

Mutable state includes things such as:

* PostgreSQL databases
* n8n runtime state
* Caddy certificates and storage
* Pi-hole runtime data
* Beszel state
* DNS blocklist databases
* monitor state
* logs
* generated application data

A clean Git tree means:

> **The declarative VPS deployment matches Git.**

It does not mean:

> **Every piece of state required for disaster recovery is backed up.**

---

# 🚀 Services

Heighliner serves several distinct roles.

## 🌐 Public Edge

**Caddy** is the public HTTPS edge for Wormlogic services hosted on the VPS and selected services reached through the private network.

Caddy owns:

* HTTPS termination
* public routing
* DNS-based certificate issuance
* reverse proxying
* selected service exposure

The repository owns Caddy configuration.

Generated certificates and Caddy runtime state do not belong in Git.

---

## ⚙️ Operations

Heighliner hosts operations-oriented services including:

* **n8n**
* **PostgreSQL**
* **Beszel**
* other services currently declared by Compose

The Compose file remains the authoritative inventory:

```bash
./dc config --services
```

---

## 🕳️ Pi-hole3

Heighliner also hosts the PVP-facing Pi-hole instance.

Its PVP-facing address is:

```text
10.9.0.1
```

Current published services include:

```text
10.9.0.1:53
10.9.0.1:8081
```

Caddy exposes the web interface as:

```text
pihole3.wormlogic.com
```

and proxies it to:

```text
10.9.0.1:8081
```

This creates two distinct dependencies:

1. `wg-pvp` must exist before Docker/Pi-hole can bind published services to `10.9.0.1`.
2. Docker must create `br-pihole` before the PVP DNS installer can configure and verify Unbound on the host side of that bridge.

The `wg-pvp` interface itself is host-owned. The service-specific deployment order is enforced by `vps-services`.

---

# 🌐 Network Architecture

Heighliner participates in several distinct WireGuard networks.

## Wormlogic

```text
wg0
10.8.0.1/24
```

Heighliner is the remote Wormlogic WireGuard endpoint.

Other current peers include:

```text
Midway       10.8.0.2
Arrakis      10.8.0.3
IX           10.8.0.4
Caladan      10.8.0.5
laptop01     10.8.0.10
laptop02     10.8.0.11
```

The home network is reachable through:

```text
10.42.0.0/16
```

---

## PVP

```text
wg-pvp
10.9.0.1/24
```

This interface provides the PVP network consumed by Pi-hole and related privacy services.

---

## Proton

```text
wg-proton
10.2.0.2/32
```

The Proton tunnel provides privacy-routed upstream connectivity for the PVP DNS path.

---

# 🧭 Ownership of the Network Stack

The split is deliberate:

```text
linux-environments
        ↓
wg0 / wg-pvp / wg-proton
        ↓
policy routing / nftables / sysctl
        ↓
host networking ready

vps-services
        ↓
Pi-hole / Unbound / PVP DNS / Caddy / application services
        ↓
service-specific systemd units + reconciliation
```

`vps-services` consumes the host networking primitives.

It remains authoritative for the application/service behavior built on top of them, including PVP DNS and Unbound configuration.

---

# 🛡️ PVP DNS

The PVP DNS subsystem provides a privacy-oriented DNS path through Heighliner.

Conceptually:

```text
PVP client
    ↓
Pi-hole3
    ↓
Unbound
    ↓
wg-proton
    ↓
Internet
```

The repo-owned installer lives under:

```text
services/pvp-dns/
```

It manages the service-side DNS environment, including:

* Unbound configuration
* DNS blocklist state
* allowlists
* AppArmor integration
* database rebuilds
* DNS update automation
* PVP DNS host-state reconciliation
* runtime validation

It installs:

```text
wormlogic-pvp-dns-update.service
wormlogic-pvp-dns-update.timer
```

The installer validates more than process state. It checks:

* GRO state on `eth0`
* Unbound's policy route through `wg-proton`
* blocklist database creation
* `unbound-checkconf`
* Unbound service health
* actual recursive DNS resolution

---

## Runtime Prerequisites

The PVP DNS installer depends on both host-provided networking and Docker-created network state.

Before it can succeed:

```text
wg-proton active
        ↓
PVP policy route available
        ↓
Docker running
        ↓
br-pihole = 172.21.0.1/24
        ↓
PVP DNS / Unbound install + verification
```

The WireGuard interfaces and PVP routing primitives belong to `linux-environments`.

The Pi-hole bridge is created by the Compose deployment in `vps-services`.

For that reason, `deploy.sh` starts/reconciles Docker and explicitly verifies `br-pihole` before invoking `services/pvp-dns/install.sh`.

The bridge dependency is **not** encoded as `Requires=docker.service` / `After=docker.service` on `unbound.service`; that direct systemd dependency causes a failed boot dependency on Heighliner. Deployment handles the bridge prerequisite procedurally instead.

---

# 🔐 Secrets

Encrypted service-secret authority lives under:

```text
secrets/vps01/
```

Secrets are encrypted with:

```text
SOPS + Heighliner's age identity
```

The age identity itself belongs to the host recovery workflow in `linux-environments`.

---

## Runtime Secrets

Top-level encrypted service-secret files are materialized beneath:

```text
runtime/vps01/secrets/
```

using:

```bash
./scripts/decrypt-secrets.sh
```

Runtime plaintext must never be committed.

Examples include service environment files and shared integration credentials.

Caddy currently consumes its Cloudflare token from:

```text
runtime/vps01/secrets/caddy.env
```

rather than from a Docker secret mount.

---

## Compose Environment Recovery

The Compose environment has its own deterministic recovery path:

```text
secrets/vps01/env/vps01.env.enc
        ↓
SOPS binary decrypt in deploy.sh
        ↓
env/vps01.env
```

`deploy.sh` restores the file with mode `0600`, validates that it is non-empty, validates the materialized runtime secrets, and renders:

```bash
./dc config
```

before starting services.

The current:

```text
env/vps01.env.example
```

contains the full non-sensitive deployment values and intentionally matches the current `env/vps01.env`. The encrypted recovery copy exists to keep rebuild behavior deterministic and consistent with the other service repositories; it is not evidence that the current env file contains secrets.

---

## Secret Ownership

Standalone service installers do **not**:

* generate authoritative secrets
* encrypt secrets
* decrypt secrets
* create their own secret stores

Runtime service-secret flow:

```text
secrets/vps01/*.enc
        ↓
decrypt-secrets.sh
        ↓
runtime/vps01/secrets/
        ↓
service installer consumes runtime secret
```

Compose-environment flow:

```text
secrets/vps01/env/vps01.env.enc
        ↓
deploy.sh
        ↓
env/vps01.env
```

This keeps recovery authority centralized while allowing service installers to consume already-materialized state.

---

# 🔑 Repository Deploy Key

Heighliner uses a repository-specific deploy key for `vps-services`:

```text
~/.ssh/id_ed25519_git_vps-services
```

Example comment:

```text
vps01:github:vps-services
```

The repository is locally bound to this identity through Git's:

```text
core.sshCommand
```

This keeps `vps-services` authentication independent from:

* the normal host SSH identity
* `linux-environments`
* other repositories

The normal scheduled SSH credential capture in `linux-environments` can then preserve that key as part of Heighliner's encrypted recovery state.

---

# 🚀 Deployment

The repo-owned deployment entry point is:

```bash
./deploy.sh
```

The deployment workflow reconciles the reproducible VPS application/configuration layer. Mutable application data still requires its own backup/restore path.

Current order:

```text
validate repository + required encrypted recovery sources
        ↓
decrypt top-level runtime secrets
        ↓
restore env/vps01.env
        ↓
validate recovered files
        ↓
render ./dc config
        ↓
start / verify wg-pvp + wg-proton
        ↓
build Caddy
        ↓
./dc up -d
        ↓
verify br-pihole = 172.21.0.1/24
        ↓
install / reconcile PVP DNS + Unbound
        ↓
verify Unbound + real DNS resolution
        ↓
install service-specific boot-order drop-ins
        ↓
install external DNS monitoring
        ↓
install image-check timer
        ↓
create / verify vps-services deploy key
        ↓
bind Git repository to deploy key
        ↓
display public deploy key
        ↓
prompt only when running interactively
```

The important dependency is:

```text
WireGuard prerequisites
        ↓
Docker / br-pihole
        ↓
PVP DNS / Unbound
```

`deploy.sh` may enable/start the already-defined WireGuard units so the service layer can reconcile itself, but the WireGuard configuration and routing primitives remain owned by `linux-environments`.

The deployment intentionally does **not** add `Requires=docker.service` or `After=docker.service` to Unbound. The bridge dependency is validated procedurally after Compose starts because the direct systemd dependency causes a failed boot dependency on Heighliner.

---

# 🛠️ `dc` Wrapper

Use the repository wrapper for Compose operations:

```bash
./dc config
./dc config --services
./dc ps
./dc logs
./dc pull
./dc build
./dc up -d
./dc down
```

Service-specific commands work normally:

```bash
./dc logs caddy
./dc logs pihole
./dc restart n8n
./dc up -d --force-recreate pihole
```

Remember:

```text
restart ≠ recreate
```

A restart does not apply changed:

* environment variables
* bind mounts
* Compose configuration
* container definitions

When Compose configuration changes:

```bash
./dc up -d
```

or explicitly:

```bash
./dc up -d --force-recreate <service>
```

---

# 🔨 Caddy

Heighliner Caddy is built locally with the required DNS provider support.

Validate configuration through the repo helper:

```bash
./caddy validate
```

The helper loads:

```text
runtime/vps01/secrets/caddy.env
```

and passes the Cloudflare token into the running Caddy environment for validation.

Caddy routing configuration is versioned.

Caddy runtime storage is not.

---

# 🔔 External DNS Monitoring

Heighliner is the natural location for external DNS health monitoring because it provides an observation point outside the home network.

The monitor observes the configured home DNS path from Heighliner's external vantage point. That makes it independent from the internal observer, but it does **not** prove every public resolver, hostname path, ISP, or client network.

Repo integration lives under:

```text
services/external-dns-monitor/
```

The installed service uses an immutable release path beneath:

```text
/opt/wormlogic/external-dns-monitor/
```

rather than executing directly from a mutable Git checkout.

This keeps runtime execution pinned to an installed release while allowing the repository to own installation and reconciliation.

The service reports observations into the central operations pipeline rather than owning correlation or alert-routing policy itself.

---

# 📊 Monitoring

`vps-services` owns monitoring for the application layer running on Heighliner.

Current repo-level monitoring includes:

```text
vps-services-image-check.service
vps-services-image-check.timer
```

along with service-specific health and update timers such as the PVP DNS updater and external DNS monitor.

The image checker follows the Wormlogic notification policy:

```text
updates available
    → notify

check error
    → notify

no changes
    → journal / stdout only
```

Monitoring should answer:

```text
Are the services running?
Are they healthy?
Did their state change?
Are container images stale?
Does the externally observed DNS path still behave as expected?
```

---

# 🔔 Event Philosophy

The monitoring model follows the same Wormlogic policy as the other service repositories:

> **Silence is success.**

Normal steady state should not create noise.

Attention should be reserved for:

* failures
* meaningful state changes
* DNS failures
* container health problems
* update availability
* deployment failures
* degraded network dependencies
* other actionable conditions

Higher-level deduplication, incident persistence and routing belong to the operations automation layer rather than individual monitoring scripts.

---

# 🔄 Recovery Flow

The intended Heighliner recovery path is:

```text
clone linux-environments
        ↓
bootstrap Heighliner
        ↓
recover age / SSH / WireGuard
        ↓
configure wg0
        ↓
configure wg-pvp + wg-proton
        ↓
configure policy routing
        ↓
reboot
        ↓
clone vps-services
        ↓
./deploy.sh
        ↓
restore service secrets + Compose environment
        ↓
reconcile Docker services
        ↓
create br-pihole
        ↓
reconcile PVP DNS / Unbound
        ↓
install monitoring
        ↓
register deploy key if new
        ↓
interactive pause only when a terminal is attached
        ↓
normal linux-environments credential capture preserves new deploy key
```

The host networking primitives must be healthy before the application layer is restored.

`deploy.sh` restores reproducible configuration and credentials; it does not yet replace mutable-state backups.

---

# ⏱️ Boot Ordering

Heighliner's services have real networking dependencies, but not every deployment dependency should become a direct systemd dependency.

## Pi-hole

Pi-hole publishes services on:

```text
10.9.0.1
```

Therefore the persistent relationship is:

```text
wg-pvp
    ↓
Docker / Pi-hole
```

`vps-services` installs the service-specific ordering drop-ins that make Docker wait for the already-defined `wg-pvp` unit.

Starting Docker before `wg-pvp` exists can cause the Pi-hole bind to fail.

---

## PVP DNS / Unbound

Unbound's privacy route depends on:

```text
wg-proton
    ↓
wormlogic-pvp policy routing
    ↓
PVP DNS host-state reconciliation
    ↓
Unbound
```

The PVP DNS installer also depends on:

```text
Docker
    ↓
br-pihole = 172.21.0.1/24
```

because Unbound is verified on the host side of that bridge.

That second relationship is handled by `deploy.sh`:

```text
./dc up -d
    ↓
verify br-pihole
    ↓
services/pvp-dns/install.sh
```

Do **not** add:

```ini
Requires=docker.service
After=docker.service
```

to the Unbound override. That direct dependency has already been shown to produce a failed boot dependency on Heighliner.

Persistent service ordering should keep the known-good WireGuard/PVP relationships without turning Docker into an Unbound requirement.

---

# 🧪 Verification

## Repository

```bash
git status --short --branch
```

---

## Compose

```bash
./dc config
./dc config --services
./dc ps
```

Include stopped services when needed:

```bash
./dc ps --all
```

---

## Compose Environment Recovery

Confirm the encrypted recovery copy can reproduce the deployment env byte-for-byte:

```bash
tmp="$(mktemp)"

sops --decrypt   --input-type json   --output-type binary   secrets/vps01/env/vps01.env.enc   > "$tmp"

cmp env/vps01.env "$tmp" &&
  echo "✓ vps01.env recovery copy is byte-identical"

rm -f "$tmp"
```

---

## WireGuard Prerequisites

```bash
sudo wg show wg0
sudo wg show wg-pvp
sudo wg show wg-proton
```

PVP routing:

```bash
ip rule show
ip route show table pvp
```

The PVP table should contain a usable route through:

```text
wg-proton
```

---

## Pi-hole Binding and Bridge

```bash
ip addr show wg-pvp
ss -lntup | grep '10\.9\.0\.1'
ip -4 addr show br-pihole
```

Expected host-side bridge address:

```text
172.21.0.1/24
```

---

## PVP DNS / Unbound

```bash
sudo systemctl is-active unbound.service
sudo unbound-checkconf
```

Confirm the Unbound process is policy-routed through Proton:

```bash
ip -4 route get 9.9.9.9 uid "$(id -u unbound)"
```

The result should use:

```text
dev wg-proton
table pvp
```

Confirm actual DNS resolution through the bridge-side Unbound listener:

```bash
dig @172.21.0.1 -p 5335 example.com A +time=5 +tries=1
```

A successful response proves more than configuration syntax or process state.

---

## Runtime Secrets

List runtime secret filenames without revealing their contents:

```bash
find runtime/vps01/secrets   -maxdepth 1   -type f   -printf '%f\n'   | sort
```

---

## Caddy

```bash
./caddy validate
./dc logs caddy
```

---

# 🧱 Backup Boundary

A complete Heighliner recovery depends on three layers:

```text
1. linux-environments
   ↓
host + machine credentials + networking

2. vps-services
   ↓
declarative application deployment + encrypted secrets

3. mutable-state backups
   ↓
databases + application-owned runtime state
```

None replaces the others.

---

# 🧠 Design Rules

A few rules keep Heighliner understandable:

* **Host bootstrap and WireGuard authority belong in `linux-environments`.**
* **Heighliner application and service behavior belong in `vps-services`.**
* **WireGuard interface definitions, topology and routing primitives are host state.**
* **PVP DNS and Unbound service configuration belong here.**
* **Repo-owned services may own their own systemd units and service-specific ordering.**
* **Docker-created network state must exist before installers that bind to or verify it.**
* **Do not encode the `br-pihole` prerequisite as a direct Unbound → Docker systemd requirement.**
* **Secrets are encrypted with SOPS at rest.**
* **Decrypted service credentials live only in runtime state.**
* **The Compose environment is separate local deployment state under `env/` with a deterministic encrypted recovery copy.**
* **Standalone installers consume secrets; they do not own them.**
* **Each repository gets its own GitHub deploy key.**
* **Deployments should be safe to rerun.**
* **Compose reconciles container state.**
* **Immutable installed releases are preferred for standalone runtime services.**
* **Monitoring should report actionable change, not routine success.**
* **External monitoring describes its actual vantage point rather than claiming universal coverage.**
* **Generated runtime state does not become accidental Git structure.**
* **Recovery paths are infrastructure and should be tested like infrastructure.**

---

# 🗺️ Repository Ownership

The Wormlogic infrastructure repositories have distinct responsibilities:

| Repository | Responsibility |
| --- | --- |
| 🧠 `linux-environments` | Host bootstrap, credentials, networking and host automation |
| 🐳 `docker-services` | Arrakis application stack |
| 🤖 `llm-services` | IX / Hermes / agent stack |
| 🚀 `vps-services` | Heighliner application and public-edge stack |
| 🪱 `wormlogic-gitops` | Shai-Hulud Talos / Flux / Kubernetes state |

The boundary is intentional:

```text
linux-environments
        ↓
prepare host

service repository
        ↓
deploy workload
```

A service repository should not duplicate host bootstrap logic.

A host bootstrap should not duplicate service deployment logic.

---

# 🔭 Future Direction

The remaining work is about making recovery increasingly boring.

The target state is:

```text
Heighliner dies
      ↓
rebuild host
      ↓
recover identities
      ↓
restore WireGuard + policy routing
      ↓
deploy vps-services
      ↓
restore mutable state
      ↓
public services return
```

The same recovery pattern should apply whether the failure is:

* a VPS replacement
* a disk loss
* a bad deployment
* a host rebuild
* a credential rotation
* a provider migration

---

# 📌 Summary

`vps-services` is the declarative deployment and operational layer for services hosted on Heighliner.

It provides:

* 🚀 VPS-hosted application deployment
* 🌐 public Caddy routing and TLS
* 🕳️ PVP-facing Pi-hole services
* 🛡️ privacy-oriented DNS integration
* 🔐 SOPS-encrypted service secrets
* 🔑 repository-specific GitHub authentication
* 📊 application and image monitoring
* 🔔 external DNS health monitoring
* ⚙️ repo-owned service installers
* 🔄 a repeatable recovery path
* 🧱 a strict boundary between host state, service state and mutable backups

The goal is simple:

> **Heighliner should be replaceable from known state without becoming a forensic exercise.**

---

## 🧑‍💻 Author

Matthew J Garry
