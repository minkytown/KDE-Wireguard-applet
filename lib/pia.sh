# PIA provider. Network requests run under a dedicated UID and may leave only
# for the short-lived destinations authorized by the firewall.
pia_catalog_host=serverlist.piaservers.net
pia_login_host=www.privateinternetaccess.com

api_request() {
    local host=$1 address=$2 port=$3
    shift 3
    ipv4 "$address" && valid_port "$port" || return 1
    printf 'add element inet walkervpn bootstrap { %s . %s timeout 100s }\n' "$address" "$port" |
        nft -f - >/dev/null || return 1
    setpriv --reuid=walker-vpn-api --regid=walker-vpn-api --clear-groups --no-new-privs \
        curl --disable --noproxy '*' --ipv4 --proto '=https' --silent --show-error --fail \
        --max-time 10 --connect-timeout 4 --max-filesize 4000000 \
        --resolve "$host:$port:$address" "$@"
}

pia_resolve() {
    local host=$1 resolver address
    case "$host" in
        "$pia_catalog_host"|"$pia_login_host") ;;
        *) return 1 ;;
    esac
    for resolver in 1.1.1.1 1.0.0.1; do
        address=$(api_request cloudflare-dns.com "$resolver" 443 \
            -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$host&type=A" |
            jq -er '[.Answer[]? | select(.type == 1) | .data][0]') || continue
        if ipv4 "$address"; then
            printf '%s\n' "$address"
            return 0
        fi
    done
    return 1
}

pia_catalog() {
    local address response
    address=$(pia_resolve "$pia_catalog_host") || return 1
    response=$(api_request "$pia_catalog_host" "$address" 443 \
        "https://$pia_catalog_host/vpninfo/servers/v6") || return 1
    printf '%s\n' "${response%%$'\n'*}" | jq -ec '
        [.regions[] | select(.offline != true and (.servers.wg | length > 0)) |
        select(.id | test("^[A-Za-z0-9_-]{1,64}$"))] | sort_by(.country, .name) |
        select(length > 0)'
}

pia_token() {
    local username=$1 password=$2 address boundary response
    [[ $username =~ ^p[0-9]{1,20}$ && -n $password && ${#password} -le 512 &&
        $password != *$'\r'* && $password != *$'\n'* ]] || return 1
    address=$(pia_resolve "$pia_login_host") || return 1
    boundary="walker-vpn-$(cat /proc/sys/kernel/random/uuid)"
    response=$(
        printf -- '--%s\r\nContent-Disposition: form-data; name="username"\r\n\r\n%s\r\n--%s\r\nContent-Disposition: form-data; name="password"\r\n\r\n%s\r\n--%s--\r\n' \
            "$boundary" "$username" "$boundary" "$password" "$boundary" |
            api_request "$pia_login_host" "$address" 443 \
                -H "Content-Type: multipart/form-data; boundary=$boundary" \
                --data-binary @- "https://$pia_login_host/api/client/v2/token"
    ) || return 1
    jq -er '.token | strings | select(length > 0 and length < 4096)' <<< "$response"
}

pia_rank() {
    local id cn address config= separator= elements= ranking options
    local -A peers=()
    if [[ -s $run/region-ranking && -z $(find "$run/region-ranking" -mmin +5 -print) ]]; then
        cat "$run/region-ranking"
        return
    fi
    while IFS=$'\t' read -r id cn address; do
        valid_region "$id" && valid_hostname "$cn" && ipv4 "$address" || continue
        if [[ ! -v peers[$address] ]]; then
            peers[$address]=1
            elements+="${elements:+, }$address . 1337 timeout 100s"
        fi
        printf -v options '%ssilent\nhead\nipv4\nnoproxy = "*"\nproto = "=https"\nconnect-timeout = 1.5\nmax-time = 2\noutput = "/dev/null"\ncacert = "%s"\nresolve = "%s:1337:%s"\nurl = "https://%s:1337/"\nwrite-out = "%%{time_appconnect}\\t%s\\n"\n' \
            "$separator" "$lib/pia-ca.crt" "$cn" "$address" "$cn" "$id"
        config+=$options
        separator=$'next\n'
    done < <(jq -r '.[] | [.id, .servers.wg[0].cn, .servers.wg[0].ip] | @tsv' <<< "$1")
    [[ -n $elements ]] || return 1
    printf 'add element inet walkervpn bootstrap { %s }\n' "$elements" | nft -f - || return 1
    ranking=$(
        { setpriv --reuid=walker-vpn-api --regid=walker-vpn-api --clear-groups --no-new-privs \
            curl --disable --parallel --parallel-immediate --parallel-max 40 --config - <<< "$config" || :; } |
            awk -F '\t' '$1 + 0 > 0 && $2 ~ /^[A-Za-z0-9_-]+$/ { print }' | sort -g | cut -f2
    )
    [[ -n $ranking ]] || return 1
    printf '%s\n' "$ranking" > "$run/region-ranking"
    printf '%s\n' "$ranking"
}

pia_profile() {
    local catalog=$1 requested=$2 token=$3 target=$4
    local id cn ip reply private public peer endpoint port server_key dns address
    local -a choices servers
    private=$(wg genkey) || return 1
    public=$(wg pubkey <<< "$private") || return 1
    if [[ $requested == optimal ]]; then
        mapfile -t choices < <(pia_rank "$catalog")
        (("${#choices[@]}")) || return 1
    else
        choices=("$requested")
    fi
    for id in "${choices[@]:0:8}"; do
        while IFS=$'\t' read -r cn ip; do
            valid_hostname "$cn" && ipv4 "$ip" || continue
            reply=$(printf '%s' "$token" | api_request "$cn" "$ip" 1337 \
                --cacert "$lib/pia-ca.crt" --get --data-urlencode pt@- \
                --data-urlencode "pubkey=$public" "https://$cn:1337/addKey") || continue
            local fields
            fields=$(jq -er --arg public "$public" '
                select(.status == "OK" and .peer_pubkey == $public) |
                [.peer_ip, .server_ip, (.server_port | tostring), .server_key,
                 (.dns_servers | map(select(type == "string" and test("^[0-9.]+$"))) | join(" "))] |
                select(all(.[]; type == "string" and length > 0 and test("^[A-Za-z0-9+.=/ -]+$"))) |
                @tsv' <<< "$reply") || continue
            IFS=$'\t' read -r peer endpoint port server_key address <<< "$fields"
            read -ra servers <<< "$address"
            [[ $peer == */* ]] || peer+=/32
            ipv4 "${peer%/*}" && [[ ${peer#*/} =~ ^([0-9]|[12][0-9]|3[0-2])$ ]] &&
                ipv4 "$endpoint" && valid_port "$port" &&
                [[ $server_key =~ ^[a-zA-Z0-9+/]{43}=$ ]] || continue
            dns=
            for address in "${servers[@]}"; do
                ipv4 "$address" || continue
                dns+=${dns:+, }$address
            done
            [[ -n $dns ]] || continue
            cat > "$target" <<PROFILE || return 1
[Interface]
PrivateKey = $private
Address = $peer
DNS = $dns
MTU = 1420

[Peer]
PublicKey = $server_key
AllowedIPs = 0.0.0.0/0
Endpoint = $endpoint:$port
PersistentKeepalive = 25
PROFILE
            printf '%s\n' "$id"
            return 0
        done < <(jq -r --arg id "$id" '.[] | select(.id == $id) |
            .servers.wg[:3][] | [.cn,.ip] | @tsv' <<< "$catalog")
    done
    return 1
}
