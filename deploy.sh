#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MACHINE_ID="vps01"
REPO_NAME="vps-services"

DEPLOY_KEY="${HOME}/.ssh/id_ed25519_git_${REPO_NAME}"
DEPLOY_KEY_PUB="${DEPLOY_KEY}.pub"

ENV_RECOVERY_FILE="$REPO_ROOT/secrets/$MACHINE_ID/env/vps01.env.enc"
ENV_FILE="$REPO_ROOT/env/vps01.env"

RUNTIME_SECRETS_DIR="$REPO_ROOT/runtime/$MACHINE_ID/secrets"
ENCRYPTED_SECRETS_DIR="$REPO_ROOT/secrets/$MACHINE_ID"

IMAGE_CHECK_SERVICE="vps-services-image-check.service"
IMAGE_CHECK_TIMER="vps-services-image-check.timer"

PIHOLE_BRIDGE="br-pihole"
PIHOLE_BRIDGE_ADDRESS="172.21.0.1/24"

cd "$REPO_ROOT"


# --------------------------------------------------
# Helpers
# --------------------------------------------------

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

require_nonempty_file() {
    [[ -s "$1" ]] || die "Required file is missing or empty: $1"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 \
        || die "Required command not found: $1"
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
require_file "$ENV_RECOVERY_FILE"

require_command git
require_command grep
require_command install
require_command ip
require_command sops
require_command ssh-keygen
require_command systemctl

[[ -x "$REPO_ROOT/dc" ]] \
    || die "Compose wrapper is not executable: $REPO_ROOT/dc"

git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "$REPO_ROOT is not a Git repository"

printf '✓ Repository: %s\n' "$REPO_ROOT"


# --------------------------------------------------
# Secrets
# --------------------------------------------------

step "Decrypting service secrets"

bash "$REPO_ROOT/scripts/decrypt-secrets.sh"

printf '✓ Runtime secrets materialized\n'


# --------------------------------------------------
# Compose environment
# --------------------------------------------------

step "Restoring Heighliner Compose environment"

mkdir -p "$(dirname "$ENV_FILE")"

ENV_TMP="$(mktemp)"

cleanup_env_tmp() {
    rm -f "$ENV_TMP"
}

trap cleanup_env_tmp EXIT

if ! sops --decrypt \
    --input-type json \
    --output-type binary \
    "$ENV_RECOVERY_FILE" \
    > "$ENV_TMP"; then

    die "Failed to decrypt $ENV_RECOVERY_FILE"
fi

require_nonempty_file "$ENV_TMP"

install -m 0600 \
    "$ENV_TMP" \
    "$ENV_FILE"

rm -f "$ENV_TMP"
trap - EXIT

printf '✓ Compose environment restored: %s\n' "$ENV_FILE"


# --------------------------------------------------
# Validate recovered state
# --------------------------------------------------

step "Validating recovered configuration"

require_nonempty_file "$ENV_FILE"

shopt -s nullglob
ENCRYPTED_SECRET_FILES=(
    "$ENCRYPTED_SECRETS_DIR"/*.enc
)
shopt -u nullglob

((${#ENCRYPTED_SECRET_FILES[@]} > 0)) \
    || die "No encrypted runtime secrets found in $ENCRYPTED_SECRETS_DIR"

for encrypted_secret in "${ENCRYPTED_SECRET_FILES[@]}"; do
    secret_name="$(basename "$encrypted_secret" .enc)"

    require_nonempty_file \
        "$RUNTIME_SECRETS_DIR/$secret_name"
done

printf '✓ All encrypted runtime secrets materialized successfully\n'

if ! "$REPO_ROOT/dc" config >/dev/null; then
    die "Docker Compose configuration could not be rendered"
fi

printf '✓ Docker Compose configuration renders successfully\n'


# --------------------------------------------------
# Ensure required tunnels are live
# --------------------------------------------------

step "Ensuring Heighliner tunnels are active"

#
# linux-environments owns the WireGuard configuration.
# vps-services depends on these tunnels and refuses to
# continue unless both are available.
#

sudo systemctl enable --now wg-quick@wg-pvp.service
sudo systemctl enable --now wg-quick@wg-proton.service

ip -4 addr show wg-pvp >/dev/null 2>&1 \
    || die "wg-pvp is not active"

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

#
# Docker must start before PVP DNS is installed because
# Unbound listens on the host side of the Pi-hole bridge.
#

"$REPO_ROOT/dc" up -d

printf '✓ Docker services started\n'

"$REPO_ROOT/dc" ps


# --------------------------------------------------
# Verify Pi-hole bridge
# --------------------------------------------------

step "Verifying Pi-hole Docker bridge"

ip -4 addr show "$PIHOLE_BRIDGE" >/dev/null 2>&1 \
    || die "Pi-hole Docker bridge is not active: $PIHOLE_BRIDGE"

ip -4 addr show "$PIHOLE_BRIDGE" |
    grep -Fq "$PIHOLE_BRIDGE_ADDRESS" \
    || die "$PIHOLE_BRIDGE does not have $PIHOLE_BRIDGE_ADDRESS"

printf '✓ %s active at %s\n' \
    "$PIHOLE_BRIDGE" \
    "$PIHOLE_BRIDGE_ADDRESS"


# --------------------------------------------------
# PVP DNS / Unbound
# --------------------------------------------------

step "Installing PVP DNS"

#
# PVP DNS and its Unbound integration are service-layer
# responsibilities owned by vps-services.
#
# Dependencies at this point:
#
#   wg-proton
#       ↓
#   Docker / br-pihole
#       ↓
#   Unbound / PVP DNS
#

bash "$REPO_ROOT/services/pvp-dns/install.sh"

if ! sudo systemctl is-active --quiet unbound.service; then
    sudo systemctl status unbound.service --no-pager || true
    die "Unbound is not active after PVP DNS installation"
fi

printf '✓ PVP DNS installed and validated\n'
printf '✓ Unbound active\n'


# --------------------------------------------------
# Persistent boot ordering
# --------------------------------------------------

step "Installing Heighliner boot dependencies"

#
# Pi-hole publishes ports specifically on 10.9.0.1, which
# belongs to wg-pvp. Docker must not start until wg-pvp exists.
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
# Unbound's PVP DNS path depends on wg-proton and on
# the PVP DNS host-state reconciliation service.
#
# Docker is also required because Unbound binds to
# the host side of br-pihole at 172.21.0.1:5335.
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

printf '✓ wg-pvp will precede Docker/Pi-hole at boot\n'
printf '✓ wg-proton and PVP DNS state will precede Unbound at boot\n'


# --------------------------------------------------
# External DNS monitor
# --------------------------------------------------

step "Installing external DNS monitor"

sudo bash \
    "$REPO_ROOT/services/external-dns-monitor/install.sh" \
    "$(git -C "$REPO_ROOT" rev-parse HEAD)" \
    --enable-timer

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

ORIGIN_URL="$(
    git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true
)"

[[ -n "$ORIGIN_URL" ]] \
    || die "Git remote 'origin' is not configured"

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

FINAL_ORIGIN="$(
    git -C "$REPO_ROOT" remote get-url origin
)"

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
printf 'Compose environment: %s\n' "$ENV_FILE"
printf 'Runtime secrets:     %s\n' "$RUNTIME_SECRETS_DIR"
printf 'wg-pvp:              %s\n' "10.9.0.1/24"
printf 'wg-proton:           %s\n' "active"
printf 'Pi-hole bridge:      %s\n' "$PIHOLE_BRIDGE_ADDRESS"
printf 'Unbound:             %s\n' "active"
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
