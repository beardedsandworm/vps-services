#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MACHINE_ID="vps01"
REPO_NAME="vps-services"

DEPLOY_KEY="${HOME}/.ssh/id_ed25519_git_${REPO_NAME}"
DEPLOY_KEY_PUB="${DEPLOY_KEY}.pub"

IMAGE_CHECK_SERVICE="vps-services-image-check.service"
IMAGE_CHECK_TIMER="vps-services-image-check.timer"

cd "$REPO_ROOT"

die() {
    printf '✗ %s\n' "$*" >&2
    exit 1
}

step() {
    printf '\n==================================================\n'
    printf '%s\n' "$*"
    printf '==================================================\n'
}

require_file() {
    [[ -f "$1" ]] || die "Required file not found: $1"
}


# --------------------------------------------------
# Validate repository
# --------------------------------------------------

step "Validating vps-services repository"

require_file "$REPO_ROOT/scripts/decrypt-secrets.sh"
require_file "$REPO_ROOT/services/pvp-dns/install.sh"
require_file "$REPO_ROOT/services/external-dns-monitor/install.sh"
require_file "$REPO_ROOT/systemd/$IMAGE_CHECK_SERVICE"
require_file "$REPO_ROOT/systemd/$IMAGE_CHECK_TIMER"
require_file "$REPO_ROOT/dc"
require_file "$REPO_ROOT/compose.yaml"

git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "$REPO_ROOT is not a Git repository"

printf '✓ Repository: %s\n' "$REPO_ROOT"


# --------------------------------------------------
# Secrets
# --------------------------------------------------

step "Decrypting service secrets"

bash "$REPO_ROOT/scripts/decrypt-secrets.sh"

printf '✓ Secrets materialized\n'


# --------------------------------------------------
# PVP DNS
# --------------------------------------------------

step "Installing PVP DNS"

bash "$REPO_ROOT/services/pvp-dns/install.sh"

printf '✓ PVP DNS installed and validated\n'


# --------------------------------------------------
# Persistent boot ordering
# --------------------------------------------------

step "Installing Heighliner boot dependencies"

#
# Pi-hole publishes ports specifically on 10.9.0.1, which belongs to wg-pvp.
# Docker must therefore not start until wg-pvp exists.
#

sudo install -d -m 0755 \
    /etc/systemd/system/wg-quick@wg-pvp.service.d

cat <<'DROPIN' | sudo tee \
    /etc/systemd/system/wg-quick@wg-pvp.service.d/wormlogic-ordering.conf \
    >/dev/null
[Unit]
Wants=network-online.target
After=network-online.target
Before=docker.service
DROPIN

sudo install -d -m 0755 \
    /etc/systemd/system/docker.service.d

cat <<'DROPIN' | sudo tee \
    /etc/systemd/system/docker.service.d/wormlogic-pihole.conf \
    >/dev/null
[Unit]
Requires=wg-quick@wg-pvp.service
After=wg-quick@wg-pvp.service
DROPIN

#
# Unbound's PVP DNS path depends on wg-proton and on the PVP DNS host-state
# reconciliation service installed by services/pvp-dns/install.sh.
#

sudo install -d -m 0755 \
    /etc/systemd/system/unbound.service.d

cat <<'DROPIN' | sudo tee \
    /etc/systemd/system/unbound.service.d/wormlogic-pvp.conf \
    >/dev/null
[Unit]
Requires=wg-quick@wg-proton.service
After=wg-quick@wg-proton.service
Wants=wormlogic-pvp-dns-update.service
After=wormlogic-pvp-dns-update.service
DROPIN

sudo systemctl daemon-reload

# Host bootstrap owns the actual WireGuard configuration.
# These ensure the already-configured interfaces participate in boot.
sudo systemctl enable wg-quick@wg-pvp.service
sudo systemctl enable wg-quick@wg-proton.service

printf '✓ wg-pvp will precede Docker/Pi-hole at boot\n'
printf '✓ wg-proton and PVP DNS state will precede Unbound at boot\n'


# --------------------------------------------------
# Ensure required tunnels are live for this deployment
# --------------------------------------------------

step "Ensuring Heighliner tunnels are active"

sudo systemctl start wg-quick@wg-pvp.service
sudo systemctl start wg-quick@wg-proton.service

ip -4 addr show wg-pvp | grep -q '10\.9\.0\.1/24' \
    || die "wg-pvp is not configured with 10.9.0.1/24"

ip -4 addr show wg-proton >/dev/null 2>&1 \
    || die "wg-proton is not active"

printf '✓ wg-pvp active at 10.9.0.1/24\n'
printf '✓ wg-proton active\n'


# --------------------------------------------------
# Caddy
# --------------------------------------------------

step "Building Caddy"

"$REPO_ROOT/dc" build caddy

printf '✓ Caddy built\n'


# --------------------------------------------------
# Docker services
# --------------------------------------------------

step "Starting vps-services"

"$REPO_ROOT/dc" up -d

printf '✓ Docker services started\n'

"$REPO_ROOT/dc" ps


# --------------------------------------------------
# External DNS monitor
# --------------------------------------------------

step "Installing external DNS monitor"

sudo bash "$REPO_ROOT/services/external-dns-monitor/install.sh" "$(git -C "$REPO_ROOT" rev-parse HEAD)" --enable-timer

printf '✓ External DNS monitor installed\n'


# --------------------------------------------------
# Image-check timer
# --------------------------------------------------

step "Installing vps-services image-check timer"

sudo install -m 0644 \
    "$REPO_ROOT/systemd/$IMAGE_CHECK_SERVICE" \
    "/etc/systemd/system/$IMAGE_CHECK_SERVICE"

sudo install -m 0644 \
    "$REPO_ROOT/systemd/$IMAGE_CHECK_TIMER" \
    "/etc/systemd/system/$IMAGE_CHECK_TIMER"

sudo systemctl daemon-reload
sudo systemctl enable --now "$IMAGE_CHECK_TIMER"

printf '✓ %s installed and enabled\n' "$IMAGE_CHECK_TIMER"


# --------------------------------------------------
# Repository deploy key
# --------------------------------------------------

step "Configuring GitHub deploy key"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

DEPLOY_KEY_CREATED=0

if [[ ! -f "$DEPLOY_KEY" ]]; then
    printf '• No vps-services deploy key found; generating one\n'

    ssh-keygen \
        -t ed25519 \
        -N '' \
        -C "${MACHINE_ID}:github:${REPO_NAME}" \
        -f "$DEPLOY_KEY"

    DEPLOY_KEY_CREATED=1
else
    printf '✓ Existing deploy key found: %s\n' "$DEPLOY_KEY"
fi

chmod 600 "$DEPLOY_KEY"

if [[ ! -f "$DEPLOY_KEY_PUB" ]]; then
    ssh-keygen -y -f "$DEPLOY_KEY" > "$DEPLOY_KEY_PUB"
fi

chmod 644 "$DEPLOY_KEY_PUB"


# --------------------------------------------------
# Ensure GitHub origin uses SSH
# --------------------------------------------------

ORIGIN_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"

[[ -n "$ORIGIN_URL" ]] || die "Git remote 'origin' is not configured"

case "$ORIGIN_URL" in
    git@github.com:*)
        printf '✓ Git origin already uses SSH: %s\n' "$ORIGIN_URL"
        ;;

    https://github.com/*)
        SSH_ORIGIN="$(
            printf '%s\n' "$ORIGIN_URL" |
            sed -E 's#^https://github\.com/(.+)$#git@github.com:\1#'
        )"

        git -C "$REPO_ROOT" remote set-url origin "$SSH_ORIGIN"

        printf '✓ Converted Git origin to SSH\n'
        printf '  %s\n' "$SSH_ORIGIN"
        ;;

    *)
        die "Unexpected Git origin: $ORIGIN_URL"
        ;;
esac


# --------------------------------------------------
# Bind this repository to its deploy key
# --------------------------------------------------

git -C "$REPO_ROOT" config --local \
    core.sshCommand \
    "ssh -i $DEPLOY_KEY -o IdentitiesOnly=yes"

printf '✓ %s is bound to its repo-specific deploy key\n' "$REPO_NAME"

FINAL_ORIGIN="$(git -C "$REPO_ROOT" remote get-url origin)"

case "$FINAL_ORIGIN" in
    git@github.com:*)
        printf '✓ SSH is the default Git transport for origin\n'
        ;;
    *)
        die "Git origin is not using SSH after configuration: $FINAL_ORIGIN"
        ;;
esac


# --------------------------------------------------
# Deployment summary
# --------------------------------------------------

step "Heighliner deployment complete"

printf 'Repository:          %s\n' "$REPO_ROOT"
printf 'Machine:             %s\n' "$MACHINE_ID"
printf 'Git origin:          %s\n' "$FINAL_ORIGIN"
printf 'Deploy private key:  %s\n' "$DEPLOY_KEY"
printf 'Deploy public key:   %s\n' "$DEPLOY_KEY_PUB"
printf '\n'

if (( DEPLOY_KEY_CREATED )); then
    printf 'A new GitHub deploy key was generated.\n'
    printf 'Add this key to the vps-services repository as a deploy key with write access:\n\n'
else
    printf 'Current vps-services GitHub deploy key:\n\n'
fi

cat "$DEPLOY_KEY_PUB"

printf '\n\n'

if [[ -t 0 ]]; then
    read -r -p "Press Enter after capturing/registering the deploy key to continue..."
    printf '\n'
fi

printf '✓ deploy.sh complete\n'
