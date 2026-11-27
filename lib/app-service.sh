app_netns_dir=/run/netns
app_netns_config=/etc/netns

app_failure() {
    printf 'ERROR %s\n' "$1"
    fail "$1"
}

app_cleanup() {
    if [[ -n ${active_record:-} && -n ${active_lease:-} ]]; then
        flock -x "$active_lease" || return 1
        # A concurrent launch can detach a new process after the first scan,
        # while it still holds its shared lease. Check again with launches blocked.
        if [[ ${cleanup_uid:-} ]]; then wait_for_app_processes "$namespace" "$cleanup_uid"; fi
        if [[ -f $active_record && $(< "$active_record") == "$namespace $app_iface $mode $work $region" ]]; then
            rm -f -- "$active_record"
        fi
    fi
    if [[ -n ${app_peer:-} ]]; then
        if [[ -z ${lock:-} ]]; then acquire || return 1; fi
        if printf 'delete element inet walkervpn app_peers { %s }\n' "$app_peer" | nft -f - >&2; then
            rm -f -- "$run/app-peer-$namespace"
        fi
        release
    fi
    if [[ ${owns_wireguard:-false} == true ]]; then
        local -a netns=()
        if [[ ${wireguard_moved:-false} == true ]]; then netns=(-n "$namespace"); fi
        if ip "${netns[@]}" link show dev "$app_iface" >/dev/null 2>&1; then
            ip "${netns[@]}" link del "$app_iface" >&2 || return 1
        fi
    fi
    if [[ -n ${namespace_keeper:-} ]]; then
        kill -TERM "$namespace_keeper" 2>/dev/null || :
        wait "$namespace_keeper" 2>/dev/null || :
    fi
    if [[ ${owns_netns:-false} == true && -e $app_netns_dir/$namespace ]]; then
        ip netns del "$namespace" >&2 || return 1
    fi
    if [[ ${owns_netns_dns:-false} == true ]]; then
        rm -rf -- "$app_netns_config/$namespace"
    fi
    # Keep the egress policy in place until the host veth is gone.
    if [[ -n ${veth:-} ]]; then
        if [[ ${firewalld_interface:-} == "$veth" ]] && systemctl is-active --quiet firewalld; then
            firewall-cmd --quiet --zone=trusted --remove-interface="$veth" >&2 || :
        fi
        if ip link show dev "$veth" >/dev/null 2>&1; then
            ip link del "$veth" >&2 || return 1
        fi
        if [[ -n ${pair:-} ]]; then
            rm -f -- "$run/direct-$namespace"
            printf 'delete element inet walkervpn direct { %s }\n' "$pair" |
                nft -f - >&2 || :
        fi
        nft -f - <<< "destroy table inet $namespace" >&2 || :
        if [[ -n ${app_route_table:-} ]]; then
            ip -4 rule del pref "$app_route_pref" iif "$veth" lookup "$app_route_table" 2>/dev/null || :
        fi
        if [[ ${app_route_denied:-false} == true ]]; then
            ip -4 rule del pref "$app_deny_pref" iif "$veth" prohibit 2>/dev/null || :
        fi
    fi
    rm -rf -- "$work"
}

start_app_namespace() {
    local attempt
    ip netns add "$namespace" || return 1
    owns_netns=true
    # Keep the namespace occupied until cleanup, including before the app
    # enters it. Other namespace tools may reap empty named namespaces.
    (
        if [[ -n ${lock:-} ]]; then exec {lock}>&-; fi
        exec nsenter --net="$app_netns_dir/$namespace" sleep infinity
    ) </dev/null >/dev/null 2>&1 &
    namespace_keeper=$!
    for ((attempt=0; attempt<100; attempt++)); do
        if [[ /proc/$namespace_keeper/ns/net -ef $app_netns_dir/$namespace ]]; then break; fi
        kill -0 "$namespace_keeper" 2>/dev/null || return 1
        sleep .01
    done
    ((attempt < 100)) || return 1
    mkdir -p -m755 "$app_netns_config" || return 1
    mkdir -m755 -- "$app_netns_config/$namespace" || return 1
    owns_netns_dns=true
    printf '%s\n' "$@" > "$app_netns_config/$namespace/resolv.conf" &&
        chmod 644 "$app_netns_config/$namespace/resolv.conf" &&
        ip -n "$namespace" link set lo up
}

start_app_tunnel() {
    local wanted=$1 config=$work/wvapp.conf address endpoint peer_ip peer_port port
    local -a profile_fields=() dns=()
    build_profile "$wanted" "$config" >/dev/null || return 1
    mapfile -t profile_fields < <(awk '
        $1 == "Address" { address=$3 }
        $1 == "Endpoint" { endpoint=$3 }
        $1 == "DNS" { for (i=3; i<=NF; i++) { sub(/,$/, "", $i); dns=dns "nameserver " $i "\n" } }
        END { if (address && endpoint && dns) printf "%s\n%s\n%s", address, endpoint, dns }
    ' "$config")
    (( ${#profile_fields[@]} >= 3 )) || return 1
    address=${profile_fields[0]} endpoint=${profile_fields[1]} dns=("${profile_fields[@]:2}")
    peer_ip=${endpoint%:*} peer_port=${endpoint##*:}
    ipv4 "$peer_ip" && valid_port "$peer_port" || return 1

    start_app_namespace "${dns[@]}" || return 1
    # WireGuard retains its UDP socket in the namespace where it was created.
    # The app sees only loopback and WireGuard, with no physical veth to use.
    ip link add "$namespace" type wireguard || return 1
    owns_wireguard=true
    app_iface=$namespace
    ip link set "$app_iface" netns "$namespace" || return 1
    wireguard_moved=true
    ip -n "$namespace" address add "$address" dev "$app_iface" &&
        ip -n "$namespace" link set "$app_iface" mtu 1420 up || return 1
    port=$(nsenter --net="$app_netns_dir/$namespace" wg show "$app_iface" listen-port) && valid_port "$port" || return 1
    app_peer="$port . $peer_ip . $peer_port"
    printf '%s %s %s\n' "$port" "$peer_ip" "$peer_port" > "$run/app-peer-$namespace" || return 1
    printf 'add element inet walkervpn app_peers { %s }\n' "$app_peer" | nft -f - || return 1
    wg-quick strip "$config" |
        awk -v port="$port" -v mark="$wgmark" '
            /^\[Interface\]$/ { print; print "ListenPort = " port; print "FwMark = " mark; next }
            { print }
        ' > "$work/wireguard.conf" || return 1
    nsenter --net="$app_netns_dir/$namespace" wg setconf "$app_iface" "$work/wireguard.conf" &&
        rm -f -- "$config" "$work/wireguard.conf" &&
        ip -4 -n "$namespace" route add default dev "$app_iface" || return 1
    nsenter --net="$app_netns_dir/$namespace" nft -f - <<RULES
table inet walker_app {
    chain output {
        type filter hook output priority -20; policy drop;
        oifname "lo" accept
        meta nfproto ipv4 oifname "$app_iface" accept
    }
}
RULES
}

app_policy() {
    local links inside uplink_index app_address reverse_mark=
    local route_table=main
    links=$(ip -n "$namespace" -j -d address show | jq -er '
        [.[] | select(.linkinfo.info_kind == "veth")] as $interfaces |
        select(($interfaces | length) == 1) |
        $interfaces[0] |
        [.addr_info[] | select(.family == "inet") | .local] as $addresses |
        select(($addresses | length) == 1) |
        [.ifname, .link_index, $addresses[0]] | @tsv
    ') || return 1
    IFS=$'\t' read -r inside link_index app_address <<< "$links"
    [[ $link_index =~ ^[0-9]+$ ]] && ipv4 "$app_address" || return 1
    links=$(ip -j -d link show | jq -er --argjson index "$link_index" --arg uplink "$uplink" '
        [first(.[] | select(.ifindex == $index and .linkinfo.info_kind == "veth") | .ifname),
         first(.[] | select(.ifname == $uplink) | .ifindex)] |
        select(length == 2) | @tsv
    ') || return 1
    IFS=$'\t' read -r veth uplink_index <<< "$links"
    valid_interface "$inside" && valid_interface "$veth" && valid_interface "$uplink" || return 1
    app_iface=$inside
    # Strict reverse-path checks can select the host tunnel for the app's
    # source and drop its ARP requests. The forward chain pins the source.
    sysctl -qw "net/ipv4/conf/$veth/rp_filter=2" || return 1
    if [[ $mode == direct ]]; then
        reverse_mark="iifname \"$veth\" oifname \"$uplink\" meta nfproto ipv4 ct mark set $bootstrap_mark"
    else
        route_table=$wgmark
    fi
    ip netns exec "$namespace" nft -f - <<RULES >&2 || return 1
table inet walker_app {
    chain output {
        type filter hook output priority -20; policy drop;
        oifname "lo" accept
        meta nfproto ipv4 oifname "$inside" accept
    }
}
RULES

    nft -f - <<RULES >&2 || return 1
table inet $namespace {
    chain input {
        type filter hook input priority -20; policy accept;
        iifname "$veth" drop
    }
    chain forward {
        type filter hook forward priority -20; policy accept;
        iifname "$veth" meta nfproto ipv6 drop
        iifname "$veth" ip saddr != $app_address drop
        iifname "$veth" oifname != "$uplink" drop
        oifname "$veth" iifname != "$uplink" drop
        $reverse_mark
    }
    chain postrouting {
        type nat hook postrouting priority srcnat - 1; policy accept;
        iifname "$veth" oifname "$uplink" ip saddr $app_address masquerade
    }
}
RULES
    # Stop route lookup if the selected table has no route even during a
    # host firewall reload.
    ip -4 rule add pref "$app_deny_pref" iif "$veth" prohibit >&2 || return 1
    app_route_denied=true
    ip -4 rule add pref "$app_route_pref" iif "$veth" lookup "$route_table" >&2 || return 1
    app_route_table=$route_table
    if [[ $mode == direct ]]; then
        [[ $uplink_index =~ ^[0-9]+$ ]] || return 1
        local indices="$link_index . $uplink_index"
        printf 'add element inet walkervpn direct { %s }\n' "$indices" | nft -f - >&2 || return 1
        pair=$indices
        printf '%s %s %s\n' "$veth" "$uplink" "$pair" > "$run/direct-$namespace" || return 1
    fi
    # Fedora's firewalld otherwise rejects forwarding to the host VPN after
    # our own chains accept it. Trust only this app's veth, after installing
    # the source/uplink restrictions and default-drop namespace policy above.
    # The input chain still blocks this veth from reaching host services.
    if systemctl is-active --quiet firewalld; then
        command -v firewall-cmd >/dev/null || return 1
        firewall-cmd --quiet --zone=trusted --add-interface="$veth" >&2 || return 1
        firewalld_interface=$veth
    fi
}

app_veth_addresses() {
    # Allocate a /30 under the manager lock. Skip any intersection with a
    # non-default route, including local addresses and routes in other tables.
    ip -j -4 route show table all | jq -r '.[] | .dst | strings | select(. != "default" and . != "0.0.0.0/0")' |
        awk -F '[./]' '
            BEGIN { base = (10 * 256 + 200) * 65536; last = base + 65535 }
            NF >= 4 {
                address = (($1 * 256 + $2) * 256 + $3) * 256 + $4
                size = 2 ^ (32 - (NF == 5 ? $5 : 32))
                start = int(address / size) * size
                end = start + size - 1
                if (start > last || end < base) next
                first_block = start < base ? 0 : int((start - base) / 4)
                last_block = end > last ? 16383 : int((end - base) / 4)
                for (block = first_block; block <= last_block; block++) used[block] = 1
            }
            END {
                for (block = 0; block < 16384; block++) {
                    if (block in used) continue
                    printf "10.200.%d.%d 10.200.%d.%d\n", int(block / 64), block % 64 * 4 + 1,
                        int(block / 64), block % 64 * 4 + 2
                    exit
                }
                exit 1
            }
        '
}

start_forwarded_app() {
    local link_index uplink addresses gateway address inside=${namespace}_s
    local -a dns=()
    if [[ $mode == direct ]]; then
        uplink=$(physical_link) || { fail 'No active physical IPv4 link was found.'; return; }
        sysctl -qw "net/ipv4/conf/$uplink/forwarding=1" || return 1
    else
        uplink=$iface
        tunnel_is_up || { fail 'The host VPN tunnel is unavailable.'; return; }
        # Also cover a host tunnel already running at service upgrade.
        sysctl -qw "net/ipv4/conf/$uplink/forwarding=1" || return 1
    fi
    mapfile -t dns < <(link_dns "$uplink" | sed 's/^/nameserver /')
    (("${#dns[@]}")) || { fail 'The selected uplink has no IPv4 DNS servers.'; return; }
    addresses=$(app_veth_addresses) || { fail 'Could not allocate an IPv4 subnet for the app.'; return; }
    read -r gateway address <<< "$addresses"
    start_app_namespace "${dns[@]}" || return 1
    ip link add "${namespace}_d" type veth peer name "$inside" netns "$namespace" || return 1
    veth=${namespace}_d
    ip -4 address add "$gateway/30" dev "$veth" &&
        ip link set dev "$veth" up &&
        ip -n "$namespace" -4 address add "$address/30" dev "$inside" &&
        ip -n "$namespace" link set dev "$inside" up &&
        ip -n "$namespace" -4 route add default via "$gateway" dev "$inside" || return 1
    app_policy || { fail 'Could not install the app isolation policy.'; return; }
    sysctl -qw "net/ipv4/conf/$veth/forwarding=1"
}

launch_app() {
    local app_kind app_id uid gid home user_entry job forward_files argc result=0 cleanup_uid=
    mode= region= namespace= work= veth= pair= active_record= active_lease= app_iface=
    owns_netns=false owns_netns_dns=false owns_wireguard=false wireguard_moved=false app_peer= namespace_keeper=
    app_route_table= app_route_denied=false firewalld_interface=
    local item
    local -a fields=() args=() session=()
    # NUL-delimited fields preserve spaces, empty arguments, and newlines.
    mapfile -d '' -t fields < <(jq -s -j --args '
        def safe_string: type == "string" and length <= 4096 and index("\u0000") == null;
        select(length == 1) | .[0] |
        select(
            (.mode == "vpn" or .mode == "direct") and
            ((.region // "host") | strings | test("^[A-Za-z0-9_-]{1,64}$")) and
            (.mode == "vpn" or (.region // "host") == "host") and
            (.kind == "native" or .kind == "flatpak") and
            (.job | strings | test("^[a-f0-9-]{36}$")) and
            ((.app_id // "") | strings | test("^[A-Za-z0-9_.-]{0,200}$")) and
            (.kind != "flatpak" or (.app_id | strings | test("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,199}$"))) and
            (.argv | type == "array" and length >= 1 and length <= 80 and all(.[]; safe_string))
        ) |
        (if (.session | type) == "object" then .session else {} end) as $env |
        ([.mode, .kind, (.app_id // ""), .job, (.forward_files != false | tostring), (.argv | length | tostring), (.region // "host")] +
            .argv + [$ARGS.positional[] as $key | $env[$key] | select(safe_string) | "\($key)=\(.)"])[] |
        ., "\u0000"
    ' -- "${app_session_keys[@]}" <<< "$request")
    if (( ${#fields[@]} < 8 )); then
        fail 'The app request contained invalid launch information.'
        return
    fi
    mode=${fields[0]} app_kind=${fields[1]} app_id=${fields[2]}
    job=${fields[3]} forward_files=${fields[4]} argc=${fields[5]}
    region=${fields[6]}
    args=("${fields[@]:7:argc}")
    session=("${fields[@]:7+argc}")
    user_entry=$(getent passwd "$account") || { fail 'The desktop account could not be found.'; return; }
    IFS=: read -r _ _ uid gid _ home _ <<< "$user_entry"
    [[ $uid =~ ^[0-9]+$ ]] && (( uid > 0 )) || return 1
    acquire && guard_init || { fail 'The app firewall could not be initialized.'; return; }
    if [[ -n $app_id ]]; then
        active_record=$run/active-$app_kind-$app_id
        if [[ -f $active_record ]]; then
            local running_mode running_region registered
            registered=$(< "$active_record")
            read -r namespace app_iface running_mode work running_region <<< "$registered" || return 1
            if [[ -e $app_netns_dir/$namespace && -f $work/lease ]]; then
                [[ $mode == "$running_mode" && $region == "${running_region:-host}" ]] ||
                    { fail 'Close the running app before using a different VPN route.'; return; }
                exec {active_lease}<"$work/lease" || return 1
                if ! flock -sn "$active_lease" ||
                    [[ ! -f $active_record || $(< "$active_record") != "$registered" ]]; then
                    printf 'RETRY\n'
                    return 1
                fi
                if [[ $mode == vpn && $region == host ]]; then ensure_host_for_app || return 1; fi
                run_app_in_namespace || result=$?
                printf '%s\n' "$result" > "$run/result-$job"
                return "$result"
            fi
            rm -f -- "$active_record" || return 1
        fi
    fi
    if [[ -n $app_id && $mode == vpn && $region == host ]]; then ensure_host_for_app || return 1; fi
    work=$(mktemp -d "$run/app.XXXXXXXX") || return 1
    namespace="wv$(od -An -N5 -tx1 /dev/urandom | tr -d ' \n')"
    trap app_cleanup EXIT
    trap 'exit 143' TERM HUP INT
    if [[ $mode == direct ]] || { [[ $region == host ]] && tunnel_exists; }; then
        start_forwarded_app || return 1
    elif [[ $region != host ]]; then
        start_app_tunnel "$region" || { fail 'Could not connect to the app’s selected VPN location.'; return; }
    elif [[ -n $app_id ]] || guard_armed || [[ -e $run/armed ]]; then
        fail 'Connect the host VPN or select a separate VPN location for this app.'
        return
    else
        start_app_tunnel optimal || { fail 'Could not register a WireGuard peer for this app.'; return; }
    fi
    if [[ $app_kind == flatpak ]]; then
        mkdir "$work/monitor" || return 1
        for item in host.conf gai.conf hosts; do
            if [[ -f /etc/$item ]]; then cp "/etc/$item" "$work/monitor/$item" || return 1; fi
        done
        cp "$app_netns_config/$namespace/resolv.conf" "$work/monitor/resolv.conf" || return 1
        chmod 755 "$work/monitor"
        chmod 444 "$work/monitor/"*
    fi
    if [[ -n $active_record ]]; then
        exec {active_lease}>"$work/lease" || return 1
        printf '%s %s %s %s %s\n' "$namespace" "$app_iface" "$mode" "$work" "$region" > "$active_record" || return 1
    fi
    run_app_in_namespace || result=$?
    wait_for_app_processes "$namespace" "$uid"
    cleanup_uid=$uid
    trap - EXIT
    app_cleanup || result=1
    printf '%s\n' "$result" > "$run/result-$job"
    return "$result"
}

# Some desktop launchers detach the GUI and exit while it still needs the
# namespace. Track its members instead of the original launcher's lifetime.
wait_for_app_processes() {
    local namespace=$1 uid=$2 members pid key real_uid rest live_pid waiter
    while members=$(ip netns pids "$namespace"); do
        live_pid=
        for pid in $members; do
            [[ $pid =~ ^[1-9][0-9]*$ && /proc/$pid/ns/net -ef $app_netns_dir/$namespace ]] || continue
            while read -r key real_uid rest; do
                [[ $key == Uid: ]] || continue
                if [[ $real_uid == "$uid" ]]; then live_pid=$pid; fi
                break
            done 2>/dev/null < "/proc/$pid/status"
            [[ -z $live_pid ]] || break
        done
        [[ -n $live_pid ]] || return 0
        # A pidfd wakes the supervisor on exit without polling a detached app.
        pidwait -U "$uid" -F - <<< "$live_pid" >/dev/null 2>&1 &
        waiter=$!
        if ! wait "$waiter" && [[ /proc/$live_pid/ns/net -ef $app_netns_dir/$namespace ]]; then
            sleep 1
        fi
    done
}

# A later launch holds a shared lease for as long as it uses the namespace.
# The creator takes an exclusive lease before removing its firewall or veth.
run_app_in_namespace() {
    release
    (
        if [[ -n $active_lease ]]; then exec {active_lease}>&-; fi
        exec ip netns exec "$namespace" bash "$lib/app-inside.sh" "$uid" "$gid" "$account" \
            "$home" "$namespace" "$app_iface" "$app_kind" "$app_id" "$work" "$forward_files" \
            "${#session[@]}" "${session[@]}" "${args[@]}"
    )
}
