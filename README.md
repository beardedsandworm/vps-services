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
Recover secrets
    ↓
Verify network prerequisites
    ↓
Install host-integrated services
    ↓
Build required images
    ↓
Reconcile containers
    ↓
Install monitoring
    ↓
Observe continuously
```

Operationally:

```text
Define → Decrypt → Validate → Deploy → Observe → Correct → Recover
```

* **Define** → Compose, Caddy, DNS and service configuration
* **Decrypt** → SOPS-encrypted service secrets
* **Validate** → confirm required host networking exists
* **Deploy** → repo-owned installers + Docker Compose
* **Observe** → timers, health checks and external monitoring
* **Correct** → update Git when desired state changes
* **Recover** → rebuild from repo + encrypted state + mutable-state backups

---

# 🖥️ Host

`vps-services` runs on:

| Host | ID | OS | Role |
| --- | --- | --- | --- |
| 🚀 Heighliner | `vps01` | Ubuntu | Public VPS / network edge / operations host |

Host bootstrap and machine-level configuration are owned by:

```text
linux-environments
```

That includes:

* base OS configuration
* packages and Docker
* machine identity
* SSH identity
* age identity
* WireGuard interfaces
* policy routing
* nftables / sysctl
* host boot ordering
* host-level system services

`vps-services` begins where the Heighliner host bootstrap ends.

---

# 🧩 Repository Structure

```text
vps-services/
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
│   └── vps01.env
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
│       └── *.enc
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
* PVP DNS installation logic
* external DNS monitor integration
* deployment scripts
* systemd units associated with repo-owned services
* SOPS-encrypted service secrets
* environment examples and non-secret deployment metadata

---

## 🖥️ Host State Lives Elsewhere

The following belong to `linux-environments`, not this repository:

```text
/etc/wireguard/wg0.conf
/etc/wireguard/wg-pvp.conf
/etc/wireguard/wg-proton.conf
```

as well as:

* WireGuard interface creation
* forwarding configuration
* policy-routing tables
* nftables rules
* sysctl configuration
* `wormlogic-pvp.service`
* host boot dependencies
* machine SSH credentials
* host age recovery identity

`vps-services` may **require and validate** those facilities.

It should not duplicate their configuration.

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

This creates an important host dependency:

> `wg-pvp` must exist before services attempt to bind to `10.9.0.1`.

That dependency is a host configuration concern and ultimately belongs in `linux-environments`.

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
host ready

vps-services
        ↓
Pi-hole / Unbound / Caddy / application services
```

`vps-services` consumes host networking.

It does not become the authority for it.

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
encrypted upstream DNS
    ↓
wg-proton
    ↓
Internet
```

The repo-owned installer lives under:

```text
services/pvp-dns/
```

It manages the application-side DNS environment, including:

* Unbound configuration
* DNS blocklist state
* allowlists
* AppArmor integration
* database rebuilds
* DNS update automation
* runtime validation

It installs:

```text
wormlogic-pvp-dns-update.service
wormlogic-pvp-dns-update.timer
```

and verifies the DNS path after installation.

---

## Host Prerequisites

The PVP DNS installer depends on host state already being correct.

Before it can succeed:

```text
wg-proton
```

must be active, and the PVP policy-routing layer must provide a valid route through the Proton tunnel.

That routing state belongs to:

```text
linux-environments
```

The deployment layer should validate this dependency rather than reproduce it.

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

Encrypted files are materialized beneath:

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

## Secret Ownership

Standalone service installers do **not**:

* generate authoritative secrets
* encrypt secrets
* decrypt secrets
* create their own secret stores

The contract is:

```text
secrets/vps01/*.enc
        ↓
decrypt-secrets.sh
        ↓
runtime/vps01/secrets/
        ↓
service installer consumes runtime secret
```

This keeps one service-secret authority for Heighliner.

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

The deployment workflow is intended to reconcile the complete VPS application layer.

Conceptually:

```text
validate repository
        ↓
decrypt secrets
        ↓
verify required host networking
        ↓
install / reconcile PVP DNS
        ↓
build Caddy
        ↓
./dc up -d
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
Press Enter to continue
```

Host networking must already be functional before service reconciliation.

`deploy.sh` may start or verify required host units, but the actual definitions remain owned by `linux-environments`.

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

The monitor checks public DNS behavior independently from the services it is validating.

Repo integration lives under:

```text
services/external-dns-monitor/
```

The installed service uses an immutable release path beneath:

```text
/opt/wormlogic/external-dns-health/
```

rather than executing directly from a mutable Git checkout.

This keeps runtime execution pinned to an installed release while allowing the repository to own installation and reconciliation.

The service reports into the central operations pipeline rather than owning alert-routing policy itself.

---

# 📊 Monitoring

`vps-services` owns monitoring for the application layer running on Heighliner.

Current repo-level monitoring includes:

```text
vps-services-image-check.service
vps-services-image-check.timer
```

along with service-specific health and update timers such as the PVP DNS updater and external DNS monitor.

Monitoring should answer:

```text
Are the services running?
Are they healthy?
Did their state change?
Are container images stale?
Can external clients still resolve the services correctly?
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
deploy application services
        ↓
register deploy key if new
        ↓
Press Enter
        ↓
capture credentials
```

The host must be healthy before the application layer is restored.

---

# ⏱️ Boot Ordering

Heighliner's services have real networking dependencies.

Two are particularly important.

## Pi-hole

Pi-hole binds directly to:

```text
10.9.0.1
```

Therefore:

```text
wg-pvp
    ↓
Docker
    ↓
Pi-hole
```

must be respected.

Starting Docker first can cause Pi-hole to fail because the bind address does not yet exist.

---

## PVP DNS

Unbound's privacy route depends on:

```text
wg-proton
    ↓
wormlogic-pvp policy routing
    ↓
PVP DNS updater
    ↓
Unbound
```

The durable ordering belongs in host configuration.

The application deploy should validate that the resulting host state exists.

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

## Pi-hole Binding

```bash
ip addr show wg-pvp
ss -lntup | grep '10\.9\.0\.1'
```

---

## Runtime Secrets

List runtime secret filenames without revealing their contents:

```bash
find runtime/vps01/secrets \
  -maxdepth 1 \
  -type f \
  -printf '%f\n' \
  | sort
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

* **Host configuration belongs in `linux-environments`.**
* **Heighliner application deployment belongs here.**
* **WireGuard topology and policy routing are host state.**
* **PVP DNS application configuration belongs here.**
* **Secrets are encrypted with SOPS at rest.**
* **Decrypted service secrets live only in runtime state.**
* **Standalone installers consume secrets; they do not own them.**
* **Each repository gets its own GitHub deploy key.**
* **Deployments should be safe to rerun.**
* **Compose reconciles container state.**
* **Immutable installed releases are preferred for standalone runtime services.**
* **Monitoring should report actionable change, not routine success.**
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
