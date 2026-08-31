#!/usr/bin/env bash
# Install one exact committed external-dns-monitor release; never deploy on import.
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  printf '%s\n' 'run this installer as root' >&2
  exit 64
fi

usage() {
  printf '%s\n' 'usage: install.sh FULL_COMMIT [--enable-timer]' >&2
  exit 64
}

[[ $# -ge 1 ]] || usage
commit=$1
shift
enable_timer=false
if [[ ${1:-} == '--enable-timer' ]]; then
  enable_timer=true
  shift
fi
[[ $# -eq 0 ]] || usage
[[ $commit =~ ^[0-9a-f]{40}$ ]] || { printf 'FULL_COMMIT must be a 40-character lowercase SHA-1\n' >&2; exit 65; }

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
project_path=services/external-dns-monitor
runtime_root=/opt/wormlogic/external-dns-monitor
releases_dir=$runtime_root/releases
release_dir=$releases_dir/$commit
current_link=$runtime_root/current
config_file=/etc/wormlogic/external-dns-monitor.toml
unit_dir=/etc/systemd/system
service=wormlogic-external-dns-monitor.service
timer=wormlogic-external-dns-monitor.timer

if ! git -C "$repo_root" cat-file -e "${commit}^{commit}"; then
  printf 'not a commit in source repository: %s\n' "$commit" >&2
  exit 65
fi
if [[ -n $(git -C "$repo_root" status --porcelain -- "$project_path") ]] || ! git -C "$repo_root" diff --quiet "$commit" -- "$project_path"; then
  printf '%s\n' 'source service differs from requested commit; commit or reset it before installation' >&2
  exit 66
fi

changed=false
install -d -o root -g root -m 0755 "$releases_dir"
if [[ -e $release_dir ]]; then
  [[ -f $release_dir/REVISION && $(<$release_dir/REVISION) == "$commit" ]] || {
    printf 'existing release does not match requested commit: %s\n' "$release_dir" >&2
    exit 67
  }
else
  staging_dir=$(mktemp -d "${releases_dir}/.staging.${commit}.XXXXXX")
  trap 'rm -rf "$staging_dir"' EXIT
  git -C "$repo_root" archive --format=tar "${commit}:${project_path}" | tar -xf - -C "$staging_dir"
  printf '%s\n' "$commit" > "$staging_dir/REVISION"
  chown -R root:root "$staging_dir"
  find "$staging_dir" -type d -exec chmod 0755 {} +
  find "$staging_dir" -type f -exec chmod 0644 {} +
  chmod 0755 "$staging_dir/external_dns_monitor.py" "$staging_dir/install.sh" "$staging_dir/verify.sh"
  mv "$staging_dir" "$release_dir"
  trap - EXIT
  changed=true
fi

if [[ ! -L $current_link || $(readlink -f "$current_link") != "$release_dir" ]]; then
  ln -sfn "releases/${commit}" "$runtime_root/.current.new"
  mv -Tf "$runtime_root/.current.new" "$current_link"
  changed=true
fi

if [[ ! -e $config_file ]]; then
  install -D -o root -g root -m 0644 "$release_dir/external-dns-monitor.toml.example" "$config_file"
  changed=true
fi
for unit in "$service" "$timer"; do
  if [[ ! -e $unit_dir/$unit ]] || ! cmp -s "$release_dir/$unit" "$unit_dir/$unit"; then
    install -o root -g root -m 0644 "$release_dir/$unit" "$unit_dir/$unit"
    changed=true
  fi
done
if [[ $changed == true ]]; then
  systemctl daemon-reload
fi
if [[ $enable_timer == true ]]; then
  systemctl enable --now "$timer"
fi
if [[ $changed == false && $enable_timer == false ]]; then
  printf 'external-dns-monitor revision=%s action=none\n' "$commit"
else
  printf 'external-dns-monitor revision=%s action=installed-or-updated\n' "$commit"
fi
