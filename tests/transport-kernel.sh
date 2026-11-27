#!/usr/bin/env bash
# Run in disposable namespaces so nftables, routes and WireGuard are real.
set -Eeuo pipefail
umask 077
if [[ ${1:-} != --isolated ]]; then
    script=$(realpath -- "${BASH_SOURCE[0]}")
    exec unshare --user --map-root-user --mount --net --pid --fork --mount-proc bash "$script" --isolated
fi
[[ $$ == 1 && $UID == 0 ]]
trap 'printf "Network fixture failed at line %s.\n" "$LINENO" >&2' ERR
dnsmasq=${WALKER_VPN_TEST_DNSMASQ:-$(command -v dnsmasq || :)}
if [[ ! -x $dnsmasq ]]; then
    echo 'Set WALKER_VPN_TEST_DNSMASQ or add dnsmasq to PATH.' >&2
    exit 1
fi
dnsmasq=$(realpath -- "$dnsmasq")

# Resolve NixOS profile links before hiding the host's runtime directory.
IFS=: read -ra search_path <<< "$PATH"
resolved_path=
for directory in "${search_path[@]}"; do
    [[ $directory == /* && $directory != /run/wrappers/* && -d $directory ]] || continue
    resolved_path+=${resolved_path:+:}$(realpath -- "$directory")
done
PATH=$resolved_path
mount --make-rprivate /
resolver_target=$(readlink -f /etc/resolv.conf)
mount -t tmpfs tmpfs /run
# Bazzite links resolv.conf into /run; keep that target valid in the fixture.
if [[ $resolver_target == /run/* ]]; then
    mkdir -p "${resolver_target%/*}"
    : > "$resolver_target"
fi
mount -t sysfs sysfs /sys
source "${BASH_SOURCE[0]%/*}/../lib/guard.sh"
source "${BASH_SOURCE[0]%/*}/../lib/session-env.sh"
(
    unshare --mount bash -c '
        source "$1/session-env.sh"
        printf "nameserver 192.0.2.53\n" > /etc/resolv.conf
        touch /run/systemd/resolve/io.systemd.Resolve
        isolate_host_resolver
        [[ $(cat /etc/resolv.conf) == "nameserver 192.0.2.53" ]]
        [[ ! -e /run/systemd/resolve/io.systemd.Resolve ]]
    ' bash "${BASH_SOURCE[0]%/*}/../lib"
)
echo 'Private DNS survives hiding the host resolver socket on Bazzite.' 
id() { [[ $* == '-u walker-vpn-api' ]] && printf '123\n'; }
ip() {
    # The disposable user namespace maps only one UID. The transport test
    # does not use the provider UID route.
    if [[ $* == "-4 rule add pref $api_uid_pref uidrange 123-123 lookup main" ]]; then return 0; fi
    command ip "$@"
}

mkdir -p "$run"
ip link add uplink type veth peer name peerlink
ip netns add fixture
ip link set dev peerlink netns fixture
ip address add 192.0.2.1/24 dev uplink
ip -n fixture address add 192.0.2.2/24 dev peerlink
ip link set uplink up
ip -n fixture link set peerlink up
ip link add "$iface" type wireguard
wg set "$iface" listen-port 45001
ip link set "$iface" up
printf 'Endpoint = 192.0.2.2:45999\n' > "$profile"
touch "$run/armed"
guard_init

ip netns exec fixture nft -f - <<'RULES'
table inet transport_test {
    counter unmatched {}
    counter registered {}
    chain input {
        type filter hook input priority filter; policy accept;
        udp dport 45999 udp sport 45000 counter name unmatched
        udp dport 45999 udp sport 45001 counter name registered
    }
}
RULES

nft -f - <<RULES
table inet inject_test_mark {
    chain output {
        type filter hook output priority -30; policy accept;
        udp sport { 45000, 45001 } meta mark set $wgmark
    }
}
RULES

send_probe() {
    printf 'fixture\n' | socat -u - "UDP4-DATAGRAM:$1:$2,bind=192.0.2.1:$3"
}
# Use the registered WireGuard port after closing the synthetic kernel socket.
# Only the WireGuard mark and complete registered UDP tuple should pass.
ip link set "$iface" down
send_probe 192.0.2.2 45999 45001
send_probe 192.0.2.2 45999 45000 2>/dev/null || :
nft delete table inet inject_test_mark
send_probe 192.0.2.2 45999 45001 2>/dev/null || :
count() {
    ip netns exec fixture nft -j list counter inet transport_test "$1" |
        jq -er '[.nftables[].counter? | objects | .packets][0]'
}
[[ $(count registered) == 1 ]]
[[ $(count unmatched) == 0 ]] || {
    echo 'The armed guard accepted a marked packet with an unregistered UDP source port.' >&2
    exit 1
}
printf 'The armed guard admits only the registered marked WireGuard tuple.\n'

# Create a WireGuard peer shared by the two tunnel clients. Private keys and
# resolver records are generated inside the disposable namespace.
lib=${BASH_SOURCE[0]%/*}/../lib
source "$lib/app-service.sh"
mount -t tmpfs tmpfs /etc/netns
wg genkey > /run/peer.key
wg genkey > /run/host.key
wg genkey > /run/app.key
peer_key=$(wg pubkey < /run/peer.key)
host_key=$(wg pubkey < /run/host.key)
app_key=$(wg pubkey < /run/app.key)
ip -n fixture link add peerwg type wireguard
ip -n fixture address add 10.91.0.1/24 dev peerwg
ip netns exec fixture wg set peerwg private-key /run/peer.key listen-port 45999 \
    peer "$host_key" allowed-ips 10.91.0.2/32 peer "$app_key" allowed-ips 10.91.0.3/32
ip -n fixture link set peerwg up
wg set "$iface" private-key /run/host.key listen-port 45001 fwmark "$wgmark" \
    peer "$peer_key" endpoint 192.0.2.2:45999 allowed-ips 0.0.0.0/0
ip address add 10.91.0.2/32 dev "$iface"
ip link set "$iface" up
ip -4 route add default dev "$iface" table "$wgmark"
ip -6 route add default dev "$iface" table "$wgmark"
ip -4 rule add pref "$tunnel_return_pref" iif "$iface" table main suppress_prefixlength 0
ip -4 rule add pref "$tunnel_pref" not fwmark "$wgmark" table "$wgmark"
ip -6 rule add pref "$tunnel_pref" not fwmark "$wgmark" table "$wgmark"
sysctl -qw net.ipv4.ip_forward=0
sysctl -qw net.ipv4.conf.all.rp_filter=1
sysctl -qw net.ipv4.conf.all.src_valid_mark=1

build_profile() {
    local region=$1 config=$2
    [[ $region == synthetic ]] || return 1
    cat > "$config" <<PROFILE
[Interface]
PrivateKey = $(< /run/app.key)
Address = 10.91.0.3/32
DNS = 10.91.0.1
[Peer]
PublicKey = $peer_key
AllowedIPs = 0.0.0.0/0
Endpoint = 192.0.2.2:45999
PROFILE
}
fail() { printf '%s\n' "$*" >&2; return 1; }
namespace=wv0123456789
work=$(mktemp -d "$run/app.XXXXXXXX")
start_app_tunnel synthetic
dedicated=$namespace
printf '%s\n' "$app_peer" > /run/dedicated-tuple
printf '45998 192.0.2.2 45999\n' > "$run/app-peer-wvffffffffff"
nft add element inet walkervpn app_peers '{ 45998 . 192.0.2.2 . 45999 }'
guard_app_peers
[[ ! -e $run/app-peer-wvffffffffff ]]
nft get element inet walkervpn app_peers "{ $(< /run/dedicated-tuple) }" >/dev/null
if nft get element inet walkervpn app_peers '{ 45998 . 192.0.2.2 . 45999 }' >/dev/null 2>&1; then
    echo 'The stale dedicated peer is still allowed.' >&2
    exit 1
fi
nft delete table inet walkervpn
guard_init
guard_armed
nft get element inet walkervpn app_peers "{ $(< /run/dedicated-tuple) }" >/dev/null
printf 'Guard recovery restored its valid active transport and removed a stale record.\n'
for chain in block_output block_forward api_only; do
    nft flush chain inet walkervpn "$chain"
    if [[ $(guard_status) != degraded ]]; then
        echo "The guard reported armed with an empty $chain chain." >&2
        exit 1
    fi
    guard_init
    [[ $(guard_status) == on ]]
    nft get element inet walkervpn app_peers "{ $(< /run/dedicated-tuple) }" >/dev/null
done
echo 'Partial firewall damage registered as degraded and recovery restored the active transport.'

# Leave a namespace with no processes in it. Forwarded startup must only
# touch its own namespace and must avoid addresses used by other routes.
ip netns add unrelated
ip -n unrelated link add foreign0 type dummy
ip -4 route add blackhole 10.200.0.0/24
ip -4 route add blackhole 10.200.1.2/32 table 12345
ip route add default via 192.0.2.2 dev uplink
physical_link() { echo uplink; }
link_dns() { if [[ $1 == uplink ]]; then echo 192.0.2.2; else echo 10.91.0.1; fi; }
exec {lock}>"$run/manager.lock"
release() { exec {lock}>&-; unset lock; }
forward_fixture() {
    local namespace=$1 mode=$2 veth= work app_iface= namespace_keeper=
    local owns_netns=false owns_netns_dns=false pair= app_route_table= app_route_denied=false
    work=$(mktemp -d "$run/app.XXXXXXXX")
    start_forwarded_app
}
direct=wv1111111111
follow=wv2222222222
ip link add unrelated0 type dummy
forward_fixture "$follow" vpn
[[ $(sysctl -n net.ipv4.conf.uplink.forwarding) == 0 ]]
forward_fixture "$direct" direct
[[ $(sysctl -n net.ipv4.ip_forward) == 0 && $(sysctl -n net.ipv4.conf.unrelated0.forwarding) == 0 ]]
[[ $(sysctl -n "net/ipv4/conf/${follow}_d/forwarding") == 1 ]]
[[ $(sysctl -n "net/ipv4/conf/${direct}_d/forwarding") == 1 ]]
echo 'App launch preserved host-wide and unrelated interface forwarding policy.'
[[ -e /run/netns/$dedicated ]]
ip -n unrelated link show dev foreign0 >/dev/null
ip -n "$direct" -4 address show dev "${direct}_s" | grep -Fq '10.200.1.10/30'
ip -n "$follow" -4 address show dev "${follow}_s" | grep -Fq '10.200.1.6/30'
echo 'Forwarded startup preserved an unrelated empty namespace and skipped overlapping routes.'

(
    namespace=wv3333333333 mode=direct work=$(mktemp -d "$run/app.XXXXXXXX")
    veth= pair= app_peer= namespace_keeper= owns_wireguard=false
    owns_netns=false owns_netns_dns=false
    ip link add "${namespace}_d" type dummy
    if start_forwarded_app 2>/dev/null; then exit 1; fi
    app_cleanup
    [[ ! -e /run/netns/$namespace && ! -e /etc/netns/$namespace ]]
    ip link show dev "${namespace}_d" >/dev/null
    ip link del "${namespace}_d"
    [[ $(sysctl -n net.ipv4.ip_forward) == 0 && $(sysctl -n net.ipv4.conf.unrelated0.forwarding) == 0 ]]
)
echo 'A failed veth creation removed only the new app namespace and resolver.'

reachable() { ip netns exec "$1" ping -q -n -c 1 -W 2 "$2" >/dev/null 2>&1; }
unreachable() {
    if reachable "$@"; then printf 'Unexpected reachability from %s to %s\n' "$1" "$2" >&2; return 1; fi
}
reachable "$direct" 192.0.2.2
reachable "$follow" 10.91.0.1
reachable "$dedicated" 10.91.0.1

start_dns() {
    ip netns exec fixture "$dnsmasq" -d --conf-file=/dev/null --log-facility=- \
        --no-hosts --no-resolv --bind-interfaces --listen-address="$1" \
        --address="/walker-vpn.test/$2" >"/run/dns-$2.log" 2>&1 &
}
start_dns 192.0.2.2 203.0.113.41
start_dns 10.91.0.1 203.0.113.42
for (( attempt=0; attempt<20; attempt++ )); do
    listeners=$(ip netns exec fixture ss -H -lnu "sport = :53")
    if [[ $listeners == *192.0.2.2:53* && $listeners == *10.91.0.1:53* ]]; then break; fi
    sleep .05
done
if (( attempt == 20 )); then cat /run/dns-*.log >&2; exit 1; fi
resolve() {
    RES_OPTIONS='attempts:1 timeout:1' ip netns exec "$1" getent -s dns ahostsv4 walker-vpn.test |
        awk 'NR == 1 { print $1 }'
}
[[ $(resolve "$direct") == 203.0.113.41 ]]
[[ $(resolve "$follow") == 203.0.113.42 ]]
[[ $(resolve "$dedicated") == 203.0.113.42 ]]
ip -n fixture -6 address add 2001:db8::2/64 dev peerlink nodad
ip -6 address add 2001:db8::1/64 dev uplink nodad
for ns in "$direct" "$follow" "$dedicated"; do unreachable "$ns" 2001:db8::2; done

# Keep the guard armed when simulating either unexpected link drop.
ip link set "$iface" down
unreachable "$follow" 10.91.0.1
reachable "$direct" 192.0.2.2
reachable "$dedicated" 10.91.0.1
if resolve "$follow" >/dev/null; then exit 1; fi
[[ $(resolve "$direct") == 203.0.113.41 ]]
[[ $(resolve "$dedicated") == 203.0.113.42 ]]
ip link set "$iface" up
ip -4 route replace default dev "$iface" table "$wgmark"
ip -6 route replace default dev "$iface" table "$wgmark"
reachable "$follow" 10.91.0.1
ip -n "$dedicated" link set "$dedicated" down
unreachable "$dedicated" 10.91.0.1
if resolve "$dedicated" >/dev/null; then exit 1; fi
[[ $(resolve "$follow") == 203.0.113.42 ]]
reachable "$follow" 10.91.0.1
reachable "$direct" 192.0.2.2
guard_armed
# Simulate manual disconnect removing host routes and disarming the guard.
ip link delete "$iface"
guard_set off
[[ $(guard_status) == off ]]
unreachable "$follow" 192.0.2.2
reachable "$direct" 192.0.2.2
keeper=$namespace_keeper
app_cleanup
if kill -0 "$keeper" 2>/dev/null || [[ -e /run/netns/$dedicated ]]; then
    echo 'Closing the dedicated namespace left its keeper or handle behind.' >&2
    exit 1
fi
printf 'Synthetic IPv4 and DNS follow the three app routes through independent tunnel drops. IPv6 did not reach the physical peer.\n'
