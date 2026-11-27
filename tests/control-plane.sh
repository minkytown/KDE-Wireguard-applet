#!/usr/bin/env bash
set -euo pipefail
lib=$(cd -- "${BASH_SOURCE[0]%/*}/../lib" && pwd)
source "$lib/guard.sh"
source "$lib/pia.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
(
    run=$scratch
    id() { printf '123\n'; }
    guard_check() { return 0; }
    ip() {
        if [[ $1 == -j ]]; then
            printf '%s\n' "$existing_rules"
        else
            printf '%s\n' "$*" >> "$scratch/ip-changes"
        fi
    }
    existing_rules='[]'
    guard_init
    mapfile -t changes < "$scratch/ip-changes"
    [[ ${changes[*]} == "-4 rule add pref $api_uid_pref uidrange 123-123 lookup main -4 rule add pref $bootstrap_pref fwmark $bootstrap_mark lookup main" ]]
    rm "$scratch/ip-changes"
    existing_rules=$(jq -nc --argjson uid "$api_uid_pref" --argjson mark "$bootstrap_pref" --arg fwmark "$bootstrap_mark" '
        [{priority:$uid,uid_start:123,uid_end:123,table:"main"},
         {priority:$mark,$fwmark,table:"main"}]')
    guard_init
    [[ ! -e $scratch/ip-changes ]]
    existing_rules=$(jq -c '. + [.[1]]' <<< "$existing_rules")
    if guard_init 2>/dev/null; then exit 1; fi
)

(
    source "$lib/app-service.sh"
    mode=vpn use_host_tunnel=true namespace=wv0123456789 uplink=tunnel
    work=$scratch/app
    mkdir "$work"
    nft() { cat >/dev/null; }
    sysctl() { [[ $* == '-qw net/ipv4/conf/outside/rp_filter=2' ]]; }
    ip() {
        case "$1 $2" in
            '-n wv0123456789')
                printf '%s\n' '[{"ifname":"inside","link_index":7,"linkinfo":{"info_kind":"veth"},"addr_info":[{"family":"inet","local":"192.0.2.2"}]}]' ;;
            '-j -d')
                printf '%s\n' '[{"ifname":"outside","ifindex":7,"linkinfo":{"info_kind":"veth"}},{"ifname":"tunnel","ifindex":8}]' ;;
            'netns exec') cat >/dev/null ;;
            '-4 rule')
                printf '%s\n' "$*" >> "$scratch/app-rules"
                # Simulate a failed lookup installation after adding the deny rule.
                [[ $3 != add || ${!#} != "$wgmark" ]] ;;
            'link show'|'link del') return 0 ;;
            *) return 1 ;;
        esac
    }
    app_route_table= app_route_denied=false
    if app_policy; then exit 1; fi
    app_cleanup
    mapfile -t changes < "$scratch/app-rules"
    [[ ${#changes[@]} == 3 &&
        ${changes[0]} == "-4 rule add pref $app_deny_pref iif outside prohibit" &&
        ${changes[1]} == "-4 rule add pref $app_route_pref iif outside lookup $wgmark" &&
        ${changes[2]} == "-4 rule del pref $app_deny_pref iif outside prohibit" ]]
)

wg() { printf '%s\n' dummy; }
key=$(printf 'A%.0s' {1..43})=
api_request() {
    cat >/dev/null
    jq -nc --arg key "$key" '{status:"OK",peer_pubkey:"dummy",peer_ip:"10.1.1.2",server_ip:"192.0.2.1",
        server_port:51820,server_key:$key,dns_servers:["10.1.1.1","10.1.1.3"]}'
}
catalog='[{"id":"test","servers":{"wg":[{"cn":"example.invalid","ip":"192.0.2.1"}]}}]'
pia_profile "$catalog" test dummy "$scratch/profile" >/dev/null
rg -Fxq 'DNS = 10.1.1.1, 10.1.1.3' "$scratch/profile"
if pia_profile "$catalog" test dummy /dev/full >/dev/null 2>&1; then exit 1; fi
printf 'Routing priority and profile generation checks passed.\n'
