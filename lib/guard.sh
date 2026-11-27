run=/run/walker-vpn
state=/var/lib/walker-vpn
iface=walkvpn0
wgmark=51872
bootstrap_mark=0x575651
api_uid_pref=11000
bootstrap_pref=11001
app_route_pref=11002
tunnel_return_pref=11003
app_deny_pref=11004
tunnel_pref=11010
profile=$run/$iface.conf

ipv4() {
    local a b c d octet
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r a b c d <<< "$1"
    for octet in "$a" "$b" "$c" "$d"; do
        [[ $octet == 0 || $octet != 0* ]] && (( 10#$octet <= 255 )) || return 1
    done
}

valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 )); }
valid_interface() { [[ $1 =~ ^[a-zA-Z0-9_.-]{1,15}$ ]]; }
valid_hostname() { [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$ ]]; }
valid_region() { [[ $1 =~ ^[a-zA-Z0-9_-]{1,64}$ ]]; }

guard_init() {
    local api_uid rules installed uid_rule mark_rule endpoint record veth uplink pair wanted=either
    api_uid=$(id -u walker-vpn-api) || return 1
    if [[ -e $run/armed ]]; then wanted=on; fi
    if ! guard_check "$wanted"; then
        local replace_table= restore_output= restore_forward=
        if nft list table inet walkervpn >/dev/null 2>&1; then
            replace_table="delete table inet walkervpn"
        fi
        if [[ -e $run/armed ]] || guard_armed; then
            restore_output="add rule inet walkervpn output jump block_output"
            restore_forward="add rule inet walkervpn forward jump block_forward"
        fi
        nft -f - <<RULES || return 1
$replace_table
table inet walkervpn {
    set bootstrap {
        type ipv4_addr . inet_service
        flags timeout
        timeout 100s
    }
    set host_peer { type inet_service . ipv4_addr . inet_service; }
    set app_peers { type inet_service . ipv4_addr . inet_service; }
    set direct { type iface_index . iface_index; }

    chain api_route {
        type route hook output priority -155; policy accept;
        meta skuid $api_uid ip daddr . tcp dport @bootstrap meta mark set $bootstrap_mark
    }

    chain api_only {
        meta mark $bootstrap_mark ip daddr . tcp dport @bootstrap accept
        drop
    }

    chain remember_transport {
        type filter hook postrouting priority -151; policy accept;
        ip daddr . tcp dport @bootstrap meta mark $bootstrap_mark ct mark set meta mark
        meta mark $wgmark udp sport . ip daddr . udp dport @host_peer ct mark set meta mark
        meta mark $wgmark udp sport . ip daddr . udp dport @app_peers ct mark set meta mark
    }

    chain restore_transport {
        type filter hook prerouting priority -151; policy accept;
        ct mark { $wgmark, $bootstrap_mark } meta mark set ct mark
    }

    chain output {
        type filter hook output priority -10; policy accept;
        meta skuid $api_uid jump api_only
    }

    chain forward {
        type filter hook forward priority -10; policy accept;
    }

    chain block_output {
        oifname { "lo", "$iface" } accept
        meta mark $wgmark udp sport . ip daddr . udp dport @host_peer accept
        meta mark $wgmark udp sport . ip daddr . udp dport @app_peers accept
        meta nfproto ipv4 meta skuid 0 udp sport 68 udp dport 67 accept
        counter drop
    }

    chain block_forward {
        meta nfproto ipv4 meta iif . meta oif @direct accept
        meta nfproto ipv4 ct state established,related meta oif . meta iif @direct accept
        oifname "$iface" accept
        iifname "$iface" ct state established,related accept
        counter drop
    }
}
$restore_output
$restore_forward
RULES
        if [[ -f $profile ]] && tunnel_is_up; then
            endpoint=$(awk '$1 == "Endpoint" { print $3 }' "$profile")
            guard_peer "$endpoint" || return 1
        fi
        for record in "$run"/direct-wv*; do
            [[ -f $record ]] || continue
            read -r veth uplink pair < "$record"
            valid_interface "$veth" && valid_interface "$uplink" || continue
            [[ -r /sys/class/net/$veth/ifindex && -r /sys/class/net/$uplink/ifindex ]] || continue
            [[ $pair == "$(< "/sys/class/net/$veth/ifindex") . $(< "/sys/class/net/$uplink/ifindex")" ]] ||
                continue
            printf 'add element inet walkervpn direct { %s }\n' "$pair" | nft -f - || return 1
        done
        guard_app_peers || return 1
    fi
    rules=$(ip -j -4 rule show) || return 1
    # Select the uplink source address at socket connect time. The nftables
    # route hook marks the approved connection for return-path filtering.
    installed=$(jq -er --argjson uid "$api_uid_pref" --argjson mark "$bootstrap_pref" '
        def rule($pref; fields): [.[] | select(.priority == $pref) | fields | join(" ")] | join(";");
        [rule($uid; [.uid_start, .uid_end, .table]), rule($mark; [.fwmark, .table])] | join("|")
    ' <<< "$rules") || return 1
    IFS='|' read -r uid_rule mark_rule <<< "$installed"
    case "$uid_rule" in
        "$api_uid $api_uid main") ;;
        '') ip -4 rule add pref "$api_uid_pref" uidrange "$api_uid-$api_uid" lookup main || return 1 ;;
        *) printf 'The routing priority %s is already in use.\n' "$api_uid_pref" >&2; return 1 ;;
    esac
    case "$mark_rule" in
        "$bootstrap_mark main") ;;
        '') ip -4 rule add pref "$bootstrap_pref" fwmark "$bootstrap_mark" lookup main || return 1 ;;
        *) printf 'The routing priority %s is already in use.\n' "$bootstrap_pref" >&2; return 1 ;;
    esac
}

guard_app_peers() {
    local record namespace port address endpoint live_endpoint live_mark
    local -a rules=("flush set inet walkervpn app_peers")
    local -a stale=()
    for record in "$run"/app-peer-wv*; do
        [[ -f $record ]] || continue
        namespace=${record##*/app-peer-}
        [[ $namespace =~ ^wv[0-9a-f]{10}$ ]] || continue
        if [[ ! -e /run/netns/$namespace ]]; then
            stale+=("$record")
            continue
        fi
        read -r port address endpoint < "$record" || continue
        valid_port "$port" && ipv4 "$address" && valid_port "$endpoint" || continue
        [[ $(nsenter --net="/run/netns/$namespace" wg show "$namespace" listen-port 2>/dev/null) == "$port" ]] || continue
        live_mark=$(nsenter --net="/run/netns/$namespace" wg show "$namespace" fwmark 2>/dev/null) || continue
        [[ $live_mark == "$(printf '0x%x' "$wgmark")" ]] || continue
        read -r _ live_endpoint < <(nsenter --net="/run/netns/$namespace" wg show "$namespace" endpoints 2>/dev/null) || continue
        [[ $live_endpoint == "$address:$endpoint" ]] || continue
        rules+=("add element inet walkervpn app_peers { $port . $address . $endpoint }")
    done
    printf '%s\n' "${rules[@]}" | nft -f - || return 1
    if ((${#stale[@]})); then rm -f -- "${stale[@]}"; fi
}

# Validate the layout as well as the jumps. A flushed regular chain returns
# to its accept-policy base chain, even when the jump still exists.
guard_check() {
    nft -j list table inet walkervpn 2>/dev/null | jq -e --arg wanted "$1" '
        def entries($key): [.nftables[] | .[$key] | objects];
        def rules($name): [entries("rule")[] | select(.chain == $name) | .expr];
        def base($name; $type; $hook; $priority):
            any(entries("chain")[];
                .name == $name and .type == $type and .hook == $hook and
                .prio == $priority and .policy == "accept");
        def blocking($name; $count):
            rules($name) | length == $count and (.[-1][-1] | has("drop"));
        def armed:
            (rules("output") | length == 2 and .[1] == [{"jump":{"target":"block_output"}}]) and
            rules("forward") == [[{"jump":{"target":"block_forward"}}]];
        ([entries("set")[].name] | sort) == ["app_peers","bootstrap","direct","host_peer"] and
        base("output"; "filter"; "output"; -10) and base("forward"; "filter"; "forward"; -10) and
        base("api_route"; "route"; "output"; -155) and
        base("remember_transport"; "filter"; "postrouting"; -151) and
        base("restore_transport"; "filter"; "prerouting"; -151) and
        (rules("api_route") | length == 1) and (rules("remember_transport") | length == 3) and
        (rules("restore_transport") | length == 1) and blocking("api_only"; 2) and
        blocking("block_output"; 5) and blocking("block_forward"; 5) and
        rules("output")[0][-1] == {"jump":{"target":"api_only"}} and
        (armed or ($wanted == "either" and
            (rules("output") | length == 1) and (rules("forward") | length == 0)))
    ' >/dev/null
}

guard_armed() { guard_check on; }

guard_status() {
    if guard_armed; then printf '%s\n' on
    elif [[ -e $run/armed ]]; then printf '%s\n' degraded
    else printf '%s\n' off
    fi
}

guard_set() {
    local api_uid redirects=
    api_uid=$(id -u walker-vpn-api) || return 1
    if [[ $1 == on ]]; then
        redirects=$'add rule inet walkervpn output jump block_output\nadd rule inet walkervpn forward jump block_forward'
    fi
    nft -f - <<RULES || return 1
flush chain inet walkervpn output
flush chain inet walkervpn forward
add rule inet walkervpn output meta skuid $api_uid jump api_only
$redirects
RULES
    if [[ $1 == on ]]; then touch "$run/armed"; else rm -f "$run/armed" "$run/preview"; fi
}

guard_peer() {
    local setting= port
    if [[ -n ${1:-} ]]; then
        ipv4 "${1%:*}" && valid_port "${1##*:}" || return 1
        port=$(wg show "$iface" listen-port) && valid_port "$port" || return 1
        setting="add element inet walkervpn host_peer { $port . ${1%:*} . ${1##*:} }"
    fi
    nft -f - <<RULES
flush set inet walkervpn host_peer
$setting
RULES
}

tunnel_exists() { [[ -e /sys/class/net/$iface ]]; }
tunnel_is_up() {
    local flags
    [[ -r /sys/class/net/$iface/flags ]] || return 1
    IFS= read -r flags < "/sys/class/net/$iface/flags" || return 1
    [[ $flags =~ ^0x[0-9a-fA-F]+$ ]] && (( flags & 1 ))
}

latest_handshake() {
    local peer timestamp
    read -r peer timestamp < <(wg show "$iface" latest-handshakes) || return 1
    printf '%s\n' "$timestamp"
}

tunnel_down() {
    local family
    ip -4 rule del pref "$tunnel_return_pref" iif "$iface" table main suppress_prefixlength 0 2>/dev/null || :
    for family in -4 -6; do
        ip "$family" rule del pref "$tunnel_pref" not fwmark "$wgmark" table "$wgmark" 2>/dev/null || :
    done
    if tunnel_exists; then
        [[ -f $profile ]] || return 1
        wg-quick down "$profile" >&2 || return 1
    elif [[ -f $profile ]]; then
        if ! systemctl is-active --quiet systemd-resolved; then
            while IFS= read -r line; do
                resolvconf -d "$line" -f || return 1
            done < <(resolvconf -l 2>/dev/null | awk -v iface="$iface" '
                /^# resolv.conf from / && ($NF==iface || $NF ~ ("[.]" iface "$")) { print $NF }')
        fi
    fi
}

tunnel_up() {
    local endpoint family rules
    endpoint=$(awk '$1 == "Endpoint" { print $3 }' "$profile")
    rules=$(ip -4 -j rule show) || return 1
    if jq -e --argjson pref "$tunnel_return_pref" 'any(.[]; .priority == $pref)' <<< "$rules" >/dev/null; then
        printf 'The routing priority %s is already in use.\n' "$tunnel_return_pref" >&2
        return 1
    fi
    for family in -4 -6; do
        rules=$(ip "$family" -j rule show) || return 1
        if jq -e --argjson pref "$tunnel_pref" 'any(.[]; .priority == $pref)' <<< "$rules" >/dev/null; then
            printf 'The routing priority %s is already in use.\n' "$tunnel_pref" >&2
            return 1
        fi
        if [[ -n $(ip "$family" route show table "$wgmark" 2>/dev/null) ]]; then
            printf 'The routing table %s is already in use.\n' "$wgmark" >&2
            return 1
        fi
    done
    wg-quick up "$profile" >&2 || return 1
    if ! guard_peer "$endpoint" ||
        ! sysctl -qw "net/ipv4/conf/$iface/forwarding=1" ||
        ! sysctl -q net.ipv4.conf.all.src_valid_mark=1 ||
        ! ip -4 route add default dev "$iface" table "$wgmark" ||
        ! ip -6 route add default dev "$iface" table "$wgmark" ||
        ! ip -4 rule add pref "$tunnel_return_pref" iif "$iface" table main suppress_prefixlength 0 ||
        ! ip -4 rule add pref "$tunnel_pref" not fwmark "$wgmark" table "$wgmark" ||
        ! ip -6 rule add pref "$tunnel_pref" not fwmark "$wgmark" table "$wgmark"; then
        tunnel_down || :
        return 1
    fi
}

make_host_profile() {
    local source=$1 target=$2
    if systemctl is-active --quiet systemd-resolved; then
        awk -v mark="$wgmark" '
            /^\[Interface\]$/ { print; print "FwMark = " mark; print "Table = off"; next }
            /^DNS = / {
                sub(/^DNS = /,""); gsub(/, /," ");
                print "PostUp = resolvectl dns %i " $0;
                print "PostUp = resolvectl domain %i ~."; next
            }
            /^AllowedIPs = / { print $0 ", ::/0"; next }
            { print }
        ' "$source" > "$target"
    else
        awk -v mark="$wgmark" '
            /^\[Interface\]$/ { print; print "FwMark = " mark; print "Table = off"; next }
            /^AllowedIPs = / { print $0 ", ::/0"; next }
            { print }
        ' "$source" > "$target"
    fi
}

physical_link() {
    local device
    while IFS= read -r device; do
        valid_interface "$device" || continue
        if [[ -e /sys/class/net/$device/device ]]; then
            printf '%s\n' "$device"
            return 0
        fi
    done < <(ip -j -4 route show table main default |
        jq -r 'sort_by(.metric // 0) | .[].dev // empty')
    return 1
}

link_dns() {
    local device=$1 server
    local -a candidates
    if systemctl is-active --quiet systemd-resolved; then
        read -ra candidates <<< "$(resolvectl dns "$device" 2>/dev/null | cut -d: -f2-)"
    else
        mapfile -t candidates < <(resolvconf -l "$device" 2>/dev/null |
            awk '$1 == "nameserver" { print $2 }')
        if (( ! ${#candidates[@]} )); then
            mapfile -t candidates < <(resolvconf -l 2>/dev/null |
                awk -v device="$device" '
                    /^# resolv.conf from / { selected = ($NF == device || index($NF, device ".") == 1) }
                    selected && $1 == "nameserver" { print $2 }
                ')
        fi
    fi
    for server in "${candidates[@]}"; do
        ipv4 "$server" && [[ $server != 127.* && $server != 0.0.0.0 ]] &&
            printf '%s\n' "$server"
    done
    return 0
}
