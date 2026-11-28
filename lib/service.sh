set -uo pipefail
umask 077
export LC_ALL=C
lib=$1
account=$2
shift 2
source "$lib/guard.sh"
source "$lib/pia.sh"
source "$lib/app-service.sh"
source "$lib/session-env.sh"

fail() { printf '%s\n' "$*" >&2; return 1; }

view=/run/walker-vpn-view
catalog_file=$state/catalog.json

status() {
    local connection=disconnected kill region= last now has_login=false
    [[ -f $state/pia-login.cred ]] && has_login=true
    kill=$(guard_status)
    if [[ -f $run/pending-region ]]; then
        region=$(< "$run/pending-region")
        connection=connecting
    elif [[ -f $run/region ]]; then
        region=$(< "$run/region")
        connection=reconnecting
        if tunnel_is_up; then
            last=$(latest_handshake) || last=
            now=$EPOCHSECONDS
            if [[ $last =~ ^[1-9][0-9]*$ ]] && (( now - last < 180 )); then
                connection=connected
            elif [[ -z $last || $last == 0 ]] && [[ ! -e $run/retrying ]]; then
                connection=connecting
            fi
        fi
    fi
    jq -nc --arg connection "$connection" --arg kill "$kill" --arg region "$region" \
        --arg bootReconnect "$(if [[ -f $state/reconnect-on-boot ]]; then echo On; else echo Off; fi)" \
        --argjson login "$has_login" '{$connection,$kill,$region,$login,$bootReconnect}'
}

publish_view() {
    local name=$1 value=$2 temp
    [[ ! -f $view/$name || $(< "$view/$name") != "$value" ]] || return 0
    temp=$(mktemp "$view/.update.XXXXXXXX") || return 1
    if printf '%s\n' "$value" > "$temp" && chmod 644 "$temp" && mv -f "$temp" "$view/$name"; then
        return 0
    fi
    rm -f "$temp"
    return 1
}

publish_status() {
    local value
    value=$(status) && publish_view status.json "$value" && touch "$view/status.json"
}

acquire() {
    exec {lock}>"$run/manager.lock"
    flock -w 65 "$lock"
}

release() {
    exec {lock}>&-
    unset lock
}

refresh_catalog() {
    local locations
    if ! pia_catalog > "$state/catalog.tmp" ||
        ! locations=$(jq -ec '[.[] | {id,name,country}]' "$state/catalog.tmp") ||
        ! mv -f "$state/catalog.tmp" "$catalog_file"; then
        rm -f "$state/catalog.tmp"
        return 1
    fi
    rm -f "$run/region-ranking"
    publish_view locations.json "$locations"
}

get_catalog() {
    if [[ ! -s $catalog_file ]] || [[ -n $(find "$catalog_file" -mmin +60 -print) ]]; then
        refresh_catalog || [[ -s $catalog_file ]] || return 1
    fi
    cat "$catalog_file"
}

save_login() (
    local username password token temporary
    local filter='strings | select(index("\u0000") == null and index("\n") == null and index("\r") == null)'
    username=$(jq -er ".username | $filter" <<< "$request") || return 1
    password=$(jq -er ".password | $filter" <<< "$request") || return 1
    token=$(pia_token "$username" "$password") || return 1
    temporary=$(mktemp -d "$state/login.XXXXXXXX") || return 1
    trap 'rm -rf -- "$temporary"' EXIT
    printf '%s\n%s\n' "$username" "$password" |
        systemd-creds encrypt --with-key=host --name=pia-login - "$temporary/credential" >&2 ||
        return 1
    mv -fT -- "$temporary/credential" "$state/pia-login.cred" || return 1
    rm -f "$run/pia-token"
    printf '%s\n' "$token" > "$run/pia-token" || rm -f "$run/pia-token"
)

saved_token() {
    local login username password token
    if [[ -s $run/pia-token && -z $(find "$run/pia-token" -mmin +10 -print) ]]; then
        cat "$run/pia-token"
        return
    fi
    login=$(systemd-creds decrypt --name=pia-login "$state/pia-login.cred" -) || return 1
    [[ $login == *$'\n'* ]] || return 1
    username=${login%%$'\n'*}
    password=${login#*$'\n'}
    token=$(pia_token "$username" "$password") || return 1
    printf '%s\n' "$token" > "$run/pia-token" || rm -f "$run/pia-token"
    printf '%s\n' "$token"
}

build_profile() {
    local region=$1 output=$2 catalog token
    [[ -f $state/pia-login.cred ]] || return 1
    catalog=$(get_catalog) && token=$(saved_token) || return 1
    if ! pia_profile "$catalog" "$region" "$token" "$output"; then
        rm -f "$run/pia-token"
        return 1
    fi
}

connect_host() {
    local wanted=$1 temp selected saved=0
    temp=$(mktemp -d "$run/connect.XXXXXXXX") || return 1
    # Arm before provider requests, and retain protection if registration or
    # tunnel setup fails. An explicit kill-off preference is still respected.
    if [[ ! -e $run/preference-off ]] && ! guard_armed; then
        guard_set on || { rm -rf -- "$temp"; return 1; }
    fi
    if ! selected=$(build_profile "$wanted" "$temp/provider.conf") ||
        ! make_host_profile "$temp/provider.conf" "$temp/host.conf"; then
        rm -rf -- "$temp"
        return 1
    fi
    if [[ -e $profile ]]; then
        cp -f "$profile" "$temp/previous.conf" || { rm -rf -- "$temp"; return 1; }
        saved=1
    fi
    if ! tunnel_down; then
        rm -rf -- "$temp"
        return 1
    fi
    if mv -f "$temp/host.conf" "$profile" && tunnel_up; then
        printf '%s\n' "$selected" > "$run/region"
        if printf '%s\n' "$selected" > "$state/last-host-region.tmp"; then
            mv -fT "$state/last-host-region.tmp" "$state/last-host-region" || :
        fi
        if [[ -f $state/reconnect-on-boot ]]; then
            printf '%s\n' "$selected" > "$state/boot-region" || return 1
        fi
        touch "$profile"
        if [[ ! -e $run/preference-off ]]; then rm -f "$run/preview"; fi
        rm -f -- "$run/retrying" "$run/manual-disconnect"
        rm -rf -- "$temp"
        return 0
    fi
    # The previous selected region stays desired even if rollback needs retries.
    if (( saved )); then
        if tunnel_down && mv -f "$temp/previous.conf" "$profile"; then
            tunnel_up || :
        fi
    elif tunnel_down; then
        rm -f "$profile" "$run/region"
        guard_peer '' || :
    fi
    rm -rf -- "$temp"
    return 1
}

disconnect_host() {
    local code=0
    # Prevent automatic recovery before attempting to remove the tunnel.
    touch "$run/manual-disconnect" || return 1
    rm -f "$run/region" "$run/retrying" "$state/boot-region"
    if tunnel_down; then
        rm -f "$profile" && guard_peer '' || code=1
    else
        code=1
    fi
    guard_set off || return 1
    return "$code"
}

recover() {
    [[ -f $run/region && -f $profile ]] || return 0
    local now last
    now=$EPOCHSECONDS
    if tunnel_is_up; then
        last=$(latest_handshake) || last=
        if [[ $last =~ ^[1-9][0-9]*$ ]] && (( now - last < 180 )); then
            rm -f "$run/retrying"
            return 0
        fi
        (( now - $(stat -c %Y "$profile") >= 35 )) || return 0
    fi
    if [[ -f $run/retrying ]]; then
        (( now - $(stat -c %Y "$run/retrying") >= 30 )) || return 0
    fi
    touch "$run/retrying"
    tunnel_down && tunnel_up
}

# Runs with the manager lock held. A desktop launch can restore the host
# policy after a cold boot, without silently switching to a dedicated tunnel.
ensure_host_for_app() {
    tunnel_is_up && return 0
    local wanted=optimal
    if [[ -e $run/manual-disconnect ]]; then
        app_failure 'The host VPN was disconnected manually. Connect it from the PIA panel to start this app.'
        return
    fi
    if [[ -f $run/region && -f $profile ]]; then
        recover || :
    elif [[ -s $state/pia-login.cred ]]; then
        if [[ -r $state/last-host-region ]]; then
            IFS= read -r wanted < "$state/last-host-region" || wanted=optimal
            valid_region "$wanted" || wanted=optimal
        fi
        printf '%s\n' "$wanted" > "$run/pending-region" || return 1
        publish_status || :
        connect_host "$wanted" || :
        rm -f "$run/pending-region"
    else
        app_failure 'Save a PIA login in the PIA panel to start this app.'
        return
    fi
    publish_status || :
    tunnel_is_up || app_failure 'Could not restore the host VPN for this app. Check the VPN location and PIA login.'
}

boot_guard() {
    # No networking here: this runs before NetworkManager at boot.
    [[ -f $state/reconnect-on-boot && -s $state/boot-region ]] || return 0
    acquire && guard_init && guard_set on && publish_status
}

maintain() {
    local app_peers=false
    find "$run" -maxdepth 1 -type f -name 'result-*' -mmin +5 -delete || :
    exec {lock}>"$run/manager.lock"
    flock -n "$lock" || return 0
    rm -f "$run/pending-region"
    if [[ -f $state/reconnect-on-boot && -s $state/boot-region &&
          ! -f $run/region && ! -f $run/manual-disconnect ]]; then
        local boot_region
        boot_region=$(< "$state/boot-region")
        if valid_region "$boot_region"; then
            guard_init && guard_set on && connect_host "$boot_region" || {
                publish_status || :
                return 1
            }
        fi
    fi
    if compgen -G "$run/app-peer-wv*" >/dev/null; then app_peers=true; fi
    if [[ -e $run/armed || -f $run/region || $app_peers == true ]]; then
        if ! guard_init || { [[ $app_peers == true ]] && ! guard_app_peers; }; then
            publish_status || :
            return 1
        fi
    fi
    if [[ -f $run/preview ]] && (( EPOCHSECONDS >= $(< "$run/preview") )); then
        guard_set off || return 1
    fi
    if ! recover; then
        publish_status || :
        return 1
    fi
    if [[ ! -s $view/locations.json && -s $catalog_file ]]; then
        local locations
        locations=$(jq -ec '[.[] | {id,name,country}]' "$catalog_file") &&
            publish_view locations.json "$locations"
    fi
    publish_status
}

control_action() {
    local command=$1 selection provider
    case "$command" in
        status) status; return ;;
        locations)
            if [[ -s $catalog_file ]]; then
                jq -ec '[.[] | {id,name,country}]' "$catalog_file"
                return
            fi
            ;;
        app-result)
            selection=$(jq -er '.job | strings' <<< "$request") &&
                [[ $selection =~ ^[a-f0-9-]{36}$ ]] || return 1
            cat "$run/result-$selection" && rm -f "$run/result-$selection"
            return
            ;;
        app) launch_app; return ;;
        boot-on|boot-off|login|forget|refresh|connect|disconnect|kill-on|kill-off|kill-preview) ;;
        *) fail 'Unknown VPN action.'; return ;;
    esac
    acquire || { fail 'The VPN service is busy.'; return; }
    if [[ $command != forget && $command != kill-off ]] && ! guard_init; then
        fail 'The VPN firewall could not be initialized.'
        return
    fi
    case "$command" in
        boot-on)
            touch "$state/reconnect-on-boot" || return 1
            if [[ -s $run/region ]]; then cp "$run/region" "$state/boot-region" || return 1; fi
            ;;
        boot-off) rm -f "$state/reconnect-on-boot" "$state/boot-region" || return 1 ;;
        login)
            provider=$(jq -er '.provider | strings' <<< "$request") &&
                [[ $provider == pia ]] && save_login ||
                { fail 'PIA login failed. Check the VPN username and password and try again.'; return; }
            ;;
        forget) rm -f "$state/pia-login.cred" "$run/pia-token" || return 1 ;;
        locations|refresh)
            if [[ $command == refresh || ! -s $view/locations.json ]]; then
                refresh_catalog || { fail 'Could not refresh PIA locations.'; return; }
            fi
            cat "$view/locations.json"
            return
            ;;
        connect)
            selection=$(jq -er '.region | strings' <<< "$request") && valid_region "$selection" || return 1
            printf '%s\n' "$selection" > "$run/pending-region" || return 1
            publish_status || :
            local connected=0
            connect_host "$selection" || connected=$?
            rm -f "$run/pending-region"
            if (( connected != 0 )); then
                publish_status || :
                fail 'Could not connect to the requested PIA location.'
                return
            fi
            ;;
        disconnect) disconnect_host || { fail 'Could not disconnect. Use Turn off kill switch to restore access.'; return; } ;;
        kill-on)
            guard_set on || return 1
            rm -f "$run/preview" "$run/preference-off" || return 1
            ;;
        kill-preview)
            if [[ ! -e $run/preview ]] && { [[ -e $run/armed ]] || guard_armed; }; then
                fail 'The kill switch is already armed.'
                return
            fi
            printf '%s\n' "$(( EPOCHSECONDS + 90 ))" > "$run/preview" || return 1
            guard_set on || { rm -f "$run/preview"; return 1; }
            ;;
        kill-off) emergency_open || return 1 ;;
    esac
    local snapshot
    snapshot=$(status) || return 1
    publish_view status.json "$snapshot" || :
    printf '%s\n' "$snapshot"
}

emergency_open() {
    if nft list table inet walkervpn >/dev/null 2>&1; then
        guard_set off || return 1
    else
        rm -f "$run/armed" "$run/preview" || return 1
    fi
    touch "$run/preference-off"
}

case "${1:-}" in
    boot-guard) boot_guard; exit $? ;;
    maintain) maintain; exit $? ;;
    emergency-open)
        acquire && emergency_open && publish_status
        exit $?
        ;;
    '') ;;
    *) exit 2 ;;
esac

# One bounded JSON line. Stderr goes to the journal. Application stdout is
# framed separately and begins only after the root-free launch environment exists.
IFS= read -r -n 32769 -t 7 request || exit 1
if (( ${#request} > 32768 )); then exit 1; fi
action=$(jq -er '.action | strings' <<< "$request") || exit 1
if [[ $action == app ]]; then
    control_action "$action"
else
    result=$(control_action "$action")
    code=$?
    if (( code == 0 )); then
        printf '%s\n' "$result"
    else
        jq -nc --arg action "$action" '{error: ("VPN action failed: " + $action + ". See journalctl -u walker-vpn@*.service.")}'
    fi
fi
