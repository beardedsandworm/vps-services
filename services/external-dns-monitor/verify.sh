#!/usr/bin/env bash
# Read-only source or installed-runtime verification for external-dns-monitor.
set -Eeuo pipefail

mode=${1:-}
[[ $mode == '' || $mode == '--diagnostic' || $mode == '--source' ]] || {
  printf '%s\n' 'usage: verify.sh [--source|--diagnostic]' >&2
  exit 64
}
source_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if [[ $mode == '--source' ]]; then
  cd "$source_dir"
  python3 -m unittest discover -s tests -q
  python3 -m py_compile external_dns_monitor.py
  bash -n install.sh verify.sh
  python3 -c 'from pathlib import Path; from external_dns_monitor import load_config; load_config(Path("external-dns-monitor.toml.example"))'
  printf '%s\n' 'external-dns-monitor source verification passed; no probes, posts, installs, or timer changes were performed.'
  exit 0
fi

runtime_root=/opt/wormlogic/external-dns-monitor
current_link=$runtime_root/current
config_file=/etc/wormlogic/external-dns-monitor.toml
token_file=/home/lightweight/vps-services/runtime/vps01/secrets/leto_ops_ingress_token
service=wormlogic-external-dns-monitor.service
timer=wormlogic-external-dns-monitor.timer

[[ -L $current_link ]] || { printf 'missing current runtime link: %s\n' "$current_link" >&2; exit 1; }
release_dir=$(readlink -f "$current_link")
revision=$(<$release_dir/REVISION)
[[ $revision =~ ^[0-9a-f]{40}$ ]] || { printf 'invalid runtime revision\n' >&2; exit 1; }
for file in "$release_dir/external_dns_monitor.py" "$config_file" "$token_file"; do
  [[ -r $file ]] || { printf 'missing or unreadable required file: %s\n' "$file" >&2; exit 1; }
done
systemd-analyze verify "/etc/systemd/system/$service" "/etc/systemd/system/$timer"
printf 'external-dns-monitor verified revision=%s\n' "$revision"
printf 'timer enabled=%s active=%s\n' "$(systemctl is-enabled "$timer" 2>/dev/null || true)" "$(systemctl is-active "$timer" 2>/dev/null || true)"
if [[ $mode == '--diagnostic' ]]; then
  "$release_dir/external_dns_monitor.py" --config "$config_file" --diagnostic
fi
