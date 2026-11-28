#!/usr/bin/env bash
set -euo pipefail
lib=$(cd -- "${BASH_SOURCE[0]%/*}/../lib" && pwd)
source <(sed '/^case "\${1:-}" in/,$d' "$lib/service.sh") "$lib" example
set -e
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
run=$scratch/run state=$scratch/state view=$scratch/view
mkdir "$run" "$state" "$view"
profile=$run/walkvpn0.conf
guard_armed() { [[ -e $run/armed ]]; }
guard_set() { [[ $1 == on ]] || exit 1; touch "$run/armed"; }
build_profile() { [[ -f $run/armed || -f $run/preference-off ]]; return 1; }
if connect_host uk; then exit 1; fi
[[ -f $run/armed ]]
rm "$run/armed"
touch "$run/preference-off"
if connect_host uk; then exit 1; fi
[[ ! -f $run/armed ]]
rm "$run/preference-off"
build_profile() { printf fixture > "$2"; printf uk; }
make_host_profile() { cp "$1" "$2"; }
tunnel_down() { :; }
tunnel_up() { return 1; }
guard_peer() { :; }
if connect_host uk; then exit 1; fi
[[ -f $run/armed && ! -f $profile ]]
rm "$run/armed"
guard_init() { :; }
publish_status() { :; }
(boot_guard)
[[ ! -e $run/armed ]]
touch "$state/reconnect-on-boot"
printf uk > "$state/boot-region"
(boot_guard)
[[ -f $run/armed ]]
printf 'Failed provider setup stays fail-closed; explicit kill-off is respected; boot reconnect arms protection before network access.\n'
