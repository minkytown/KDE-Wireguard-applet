#!/usr/bin/env bash
set -euo pipefail
lib=$(cd -- "${BASH_SOURCE[0]%/*}/../lib" && pwd)
source "$lib/session-env.sh"
source "$lib/app-service.sh"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
run=$scratch
account=example
app_netns_dir=$scratch/netns
mkdir "$app_netns_dir"
getent() { printf 'example:x:1000:100:Example:/home/example:/bin/sh\n'; }
acquire() { :; }
guard_init() { :; }
guard_armed() { return 1; }
tunnel_exists() { return 1; }
ensure_host_for_app() { return 1; }
fail() { return 1; }
start_app_tunnel() {
    printf '%s\n' "$1" > "$run/selected"
    touch "$work/partial-profile"
    return 1
}
request='{"mode":"vpn","kind":"native","app_id":"org.example.Client","job":"00000000-0000-0000-0000-000000000001","argv":["example-client"]}'

if (launch_app); then exit 1; fi
[[ ! -e $run/selected ]]
(request=$(jq -c '.region = "test-location"' <<< "$request"); launch_app) && exit 1
[[ $(< "$run/selected") == test-location ]]
(request=$(jq -c '.app_id = ""' <<< "$request"); launch_app) && exit 1
[[ $(< "$run/selected") == optimal ]]
[[ -z $(find "$run" -maxdepth 1 -name 'app.*' -print -quit) ]]
printf 'A managed host-following app cannot silently select its own tunnel.\n'

# Simulate the creator starting cleanup while a second launch still holds a
# lease and then detaches. Its final namespace scan must hold an exclusive lease.
work=$run/work
mkdir "$work"
namespace=wv0123456789 app_iface=fixture mode=vpn region=host
active_record=$run/active-native-org.example.Client
printf '%s %s %s %s %s\n' "$namespace" "$app_iface" "$mode" "$work" "$region" > "$active_record"
cleanup_uid=1000
exec {active_lease}>"$work/lease"
(
    flock -s 9
    touch "$run/shared"
    while [[ ! -e $run/cleanup-started ]]; do sleep .01; done
    touch "$run/detached"
) 9<"$work/lease" &
repeat=$!
while [[ ! -e $run/shared ]]; do sleep .01; done
wait_for_app_processes() {
    [[ $1 == "$namespace" && $2 == "$cleanup_uid" && -e $run/detached ]]
    if flock -sn "$work/lease" true; then return 1; fi
    [[ -f $active_record ]]
    touch "$run/rescanned"
}
touch "$run/cleanup-started"
app_cleanup
wait "$repeat"
[[ -e $run/rescanned && ! -e $active_record && ! -e $work ]]
printf 'Cleanup rescans after the final repeat-launch lease is released.\n'
