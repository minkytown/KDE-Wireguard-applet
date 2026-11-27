#!/usr/bin/env bash
set -euo pipefail
lib=$(cd -- "${BASH_SOURCE[0]%/*}/../lib" && pwd)
source <(sed '/^case "\${1:-}" in/,$d' "$lib/service.sh") "$lib" example
set -e
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
run=$scratch/run state=$scratch/state view=$scratch/view
mkdir "$run" "$state" "$view"
catalog_file=$state/catalog.json
profile=$run/walkvpn0.conf
guard_init() { :; }
guard_set() { [[ $1 == on ]]; touch "$run/armed"; }
recover() { :; }
publish_status() { :; }
connect_host() { [[ -f $run/armed && $1 == uk ]]; printf uk > "$run/region"; }
printf uk > "$state/boot-region"
(maintain)
[[ ! -f $run/region ]]
touch "$state/reconnect-on-boot"
(maintain)
[[ $(< "$run/region") == uk ]]
rm "$run/region"
touch "$run/manual-disconnect"
(maintain)
[[ ! -f $run/region ]]
guard_peer() { :; }
guard_set() { :; }
tunnel_down() { :; }
disconnect_host
[[ ! -f $state/boot-region ]]
printf 'Boot recovery is opt-in, arms the firewall first, and respects Disconnect.\n'
