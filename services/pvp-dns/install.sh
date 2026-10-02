#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUNTIME_DIR="/usr/local/lib/wormlogic-pvp-dns"
DB_DIR="/var/lib/unbound"
DB_FILE="$DB_DIR/pvp-dnsbl.sqlite"

UNBOUND_CONF="/etc/unbound/unbound.conf.d/pvp.conf"

APPARMOR_PROFILE="/etc/apparmor.d/usr.sbin.unbound"
APPARMOR_LOCAL="/etc/apparmor.d/local/usr.sbin.unbound"

UPDATE_SERVICE="wormlogic-pvp-dns-update.service"
UPDATE_TIMER="wormlogic-pvp-dns-update.timer"

DNS_TEST_DOMAIN="example.com"
DNS_TEST_PORT="5335"

if [[ $EUID -eq 0 ]]; then
    SUDO=()
else
    SUDO=(sudo)
fi

require_file() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        echo "✗ Required file not found: $file"
        exit 1
    fi
}

for file in \
    "$HERE/build-blocklists.py" \
    "$HERE/dnsbl_module.py" \
    "$HERE/ensure-host-state.sh" \
    "$HERE/pvp.conf" \
    "$HERE/$UPDATE_SERVICE" \
    "$HERE/$UPDATE_TIMER"
do
    require_file "$file"
done

echo "=== Installing PVP DNS prerequisites ==="

packages=(
    unbound
    python3-unbound
    ca-certificates
    ethtool
    apparmor
    dnsutils
)

missing_packages=()

for package in "${packages[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null |
        grep -q 'ok installed'; then
        missing_packages+=("$package")
    fi
done

if ((${#missing_packages[@]} > 0)); then
    echo "• Installing: ${missing_packages[*]}"
    "${SUDO[@]}" apt-get update
    "${SUDO[@]}" apt-get install -y "${missing_packages[@]}"
else
    echo "✓ Required packages already installed"
fi

echo
echo "=== Installing PVP DNS runtime ==="

"${SUDO[@]}" install \
    -d -o root -g root -m 0755 \
    "$RUNTIME_DIR"

"${SUDO[@]}" install \
    -d -o unbound -g unbound -m 0755 \
    "$DB_DIR"

"${SUDO[@]}" install \
    -o root -g root -m 0755 \
    "$HERE/build-blocklists.py" \
    "$RUNTIME_DIR/build-blocklists.py"

"${SUDO[@]}" install \
    -o root -g root -m 0755 \
    "$HERE/ensure-host-state.sh" \
    "$RUNTIME_DIR/ensure-host-state.sh"

"${SUDO[@]}" install \
    -o root -g root -m 0644 \
    "$HERE/dnsbl_module.py" \
    "$RUNTIME_DIR/dnsbl_module.py"

"${SUDO[@]}" install \
    -o root -g root -m 0644 \
    "$HERE/pvp.conf" \
    "$UNBOUND_CONF"

echo "✓ PVP DNS runtime installed"

echo
echo "=== Installing AppArmor permissions ==="

if [[ ! -f "$APPARMOR_PROFILE" ]]; then
    echo "✗ Unbound AppArmor profile not found: $APPARMOR_PROFILE"
    exit 1
fi

if ! grep -Fq '<local/usr.sbin.unbound>' "$APPARMOR_PROFILE"; then
    echo "✗ Unbound AppArmor profile does not include its local override"
    echo "  Refusing to modify the distro-owned profile automatically."
    exit 1
fi

apparmor_temp="$(mktemp)"
trap 'rm -f "$apparmor_temp"' EXIT

cat > "$apparmor_temp" <<'APPARMOR'
# Managed by vps-services/services/pvp-dns/install.sh.
# Permissions required by the Wormlogic Unbound Python DNSBL module.

/usr/local/lib/wormlogic-pvp-dns/ r,
/usr/local/lib/wormlogic-pvp-dns/** r,

/var/lib/unbound/pvp-dnsbl.sqlite rk,

/etc/unbound/ r,
/usr/local/lib/python3.*/dist-packages/ r,
APPARMOR

"${SUDO[@]}" install \
    -o root -g root -m 0644 \
    "$apparmor_temp" \
    "$APPARMOR_LOCAL"

"${SUDO[@]}" apparmor_parser -r "$APPARMOR_PROFILE"

echo "✓ AppArmor local override installed"

echo
echo "=== Installing systemd units ==="

"${SUDO[@]}" install \
    -o root -g root -m 0644 \
    "$HERE/$UPDATE_SERVICE" \
    "/etc/systemd/system/$UPDATE_SERVICE"

"${SUDO[@]}" install \
    -o root -g root -m 0644 \
    "$HERE/$UPDATE_TIMER" \
    "/etc/systemd/system/$UPDATE_TIMER"

"${SUDO[@]}" systemctl daemon-reload

# The service is enabled independently because it also restores the host
# prerequisites required by PVP DNS on every boot.
"${SUDO[@]}" systemctl enable "$UPDATE_SERVICE"
"${SUDO[@]}" systemctl enable --now "$UPDATE_TIMER"

echo "✓ PVP DNS update service and timer installed"

echo
echo "=== Building initial blocklist database ==="

"${SUDO[@]}" systemctl start "$UPDATE_SERVICE"

# The update unit uses a non-blocking try-restart so it cannot deadlock against
# its Before=unbound.service ordering. During installation, explicitly wait for
# the final Unbound restart and validate it.
"${SUDO[@]}" systemctl restart unbound.service

if ! systemctl is-active --quiet unbound.service; then
    echo "✗ Unbound failed to start"
    "${SUDO[@]}" systemctl --no-pager --full status unbound.service || true
    exit 1
fi

echo
echo "=== Verifying PVP DNS state ==="

gro_state="$(
    ethtool -k eth0 |
        awk -F': ' '$1 == "generic-receive-offload" { print $2; exit }'
)"

if [[ "$gro_state" != "off" ]]; then
    echo "✗ GRO is not disabled on eth0"
    exit 1
fi

unbound_uid="$(id -u unbound)"

route="$(
    ip -4 route get 9.9.9.9 uid "$unbound_uid"
)"

if [[ "$route" != *"dev wg-proton"* ||
      "$route" != *"table pvp"* ]]; then
    echo "✗ Unbound policy routing validation failed"
    echo "  $route"
    exit 1
fi

if [[ ! -s "$DB_FILE" ]]; then
    echo "✗ Blocklist database was not created: $DB_FILE"
    exit 1
fi

"${SUDO[@]}" unbound-checkconf

echo "✓ Unbound configuration is valid"
echo "✓ Unbound policy routing uses wg-proton"


# --------------------------------------------------
# End-to-end DNS verification
# --------------------------------------------------

echo
echo "=== Verifying recursive DNS resolution ==="

DNS_TEST_OK=0
DNS_TEST_SERVER=""

for server in \
    127.0.0.1 \
    172.21.0.1
do
    answer="$(
        dig \
            @"$server" \
            -p "$DNS_TEST_PORT" \
            "$DNS_TEST_DOMAIN" \
            A \
            +time=5 \
            +tries=1 \
            +short \
            2>/dev/null || true
    )"

    if [[ -n "$answer" ]]; then
        DNS_TEST_OK=1
        DNS_TEST_SERVER="$server"
        break
    fi
done

if (( ! DNS_TEST_OK )); then
    echo "✗ Unbound did not resolve $DNS_TEST_DOMAIN"
    echo "  Tested:"
    echo "    127.0.0.1:$DNS_TEST_PORT"
    echo "    172.21.0.1:$DNS_TEST_PORT"
    echo
    "${SUDO[@]}" systemctl --no-pager --full status unbound.service || true
    exit 1
fi

echo "✓ Recursive DNS resolution succeeded"
echo "  Resolver: $DNS_TEST_SERVER:$DNS_TEST_PORT"
echo "  Query:    $DNS_TEST_DOMAIN A"


# --------------------------------------------------
# Installation summary
# --------------------------------------------------

echo
echo "✓ PVP DNS installation complete"
echo "  Unbound config:    $UNBOUND_CONF"
echo "  DNSBL module:      $RUNTIME_DIR/dnsbl_module.py"
echo "  DNSBL database:    $DB_FILE"
echo "  AppArmor override: $APPARMOR_LOCAL"
echo "  GRO:                disabled on eth0"
echo "  PVP route:          wg-proton"
echo "  DNS test:           $DNS_TEST_SERVER:$DNS_TEST_PORT"
echo "  Update timer:       $UPDATE_TIMER"
echo

"${SUDO[@]}" systemctl list-timers "$UPDATE_TIMER" --no-pager
