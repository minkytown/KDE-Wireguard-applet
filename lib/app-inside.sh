set -uo pipefail
uid=$1 gid=$2 user=$3 home=$4 namespace=$5 app_iface=$6 kind=$7 app_id=$8 work=$9
shift 9
forward_files=$1
env_count=$2
shift 2
session=("${@:1:env_count}")
shift "$env_count"
runtime=/run/user/$uid
session_bus=unix:path=$runtime/bus

if [[ ! /proc/self/ns/net -ef /run/netns/$namespace || /proc/self/ns/net -ef /proc/1/ns/net ||
    /proc/self/ns/mnt -ef /proc/1/ns/mnt ]]; then
    printf 'The app process did not enter the expected network and mount namespaces.\n' >&2
    exit 1
fi
if [[ ! -s /etc/resolv.conf ]] || ! ip link show dev "$app_iface" >/dev/null; then
    printf 'The app namespace has no resolver configuration or expected network interface.\n' >&2
    exit 1
fi

if ! nft -j list chain inet walker_app output | jq -e '
    any(.nftables[].chain?; .hook == "output" and .type == "filter" and .policy == "drop")
' >/dev/null; then
    printf 'The app namespace is missing its default-drop firewall.\n' >&2
    exit 1
fi

source "${BASH_SOURCE[0]%/*}/session-env.sh"
# nss-resolve must not reach the host socket; the private DNS file stays usable.
isolate_host_resolver || exit 1
read_desktop_timezone /etc/localtime /etc/timezone
if [[ -n $desktop_tzdir ]]; then session+=("TZDIR=$desktop_tzdir"); fi
if [[ -n $desktop_tz ]]; then session+=("TZ=$desktop_tz"); fi

if [[ $kind == flatpak ]]; then
    timezone_options=(--unset-env=TZDIR)
    if [[ -n $desktop_tz ]]; then
        timezone_options+=("--env=TZ=$desktop_tz")
    elif [[ -f /etc/localtime ]]; then
        # Flatpak needs a zone name to generate /etc/localtime. For a copied
        # tzfile with no known name, share just that file through its monitor.
        (
            temporary=$(mktemp "$work/monitor/.localtime.XXXXXXXX") || exit 1
            trap 'rm -f -- "$temporary"' EXIT
            install -m444 /etc/localtime "$temporary" && mv -fT "$temporary" "$work/monitor/localtime"
        ) || exit 1
        timezone_options+=(--env=TZ=:/run/host/monitor/localtime)
    fi
    # Enter the directory first so the kernel pins the target and rejects
    # other file types. Mount only within this private mount namespace.
    (
        cd -P -- "$runtime/.flatpak-helper/monitor" || exit 1
        [[ $(stat -c %u .) == "$uid" ]] || exit 1
        LIBMOUNT_FORCE_MOUNT2=always mount --no-canonicalize --bind "$work/monitor" /proc/self/cwd
    ) || exit 1
    mapfile -t dns < <(awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf)
    (("${#dns[@]}")) || exit 1
    check='
        set -eu
        awk -F : -v iface="$1" '"'"'$1 ~ "^[[:space:]]*" iface "$" { found=1 } END { exit !found }'"'"' /proc/net/dev
        shift
        command=$1
        shift
        while [ "$1" != -- ]; do
            awk -v server="$1" '"'"'$1 == "nameserver" && $2 == server { found=1 } END { exit !found }'"'"' /etc/resolv.conf
            shift
        done
        shift
        exec "$command" "$@"
    '
    command=$1
    shift
    forwarded=()
    if [[ $forward_files == true ]]; then
        for argument; do
            case "$argument" in
                @@|@@u) exit 1 ;;
                file://*) forwarded+=(@@u "$argument" @@) ;;
                /*) forwarded+=(@@ "$argument" @@) ;;
                *) forwarded+=("$argument") ;;
            esac
        done
        set -- --file-forwarding --command=sh "$app_id" -c "$check" walker-vpn \
            "$app_iface" "$command" "${dns[@]}" -- "${forwarded[@]}"
    else
        set -- --command=sh "$app_id" -c "$check" walker-vpn \
            "$app_iface" "$command" "${dns[@]}" -- "$@"
    fi
    # Flatpak uses the host TZDIR to set up /etc/localtime, then the app
    # resolves named zones using the database visible inside the sandbox.
    set -- "${WALKER_VPN_FLATPAK:-flatpak}" run --share=network --nosocket=session-bus --nosocket=system-bus \
        --talk-name=org.kde.StatusNotifierWatcher --no-talk-name=org.freedesktop.Flatpak "${timezone_options[@]}" "$@"
else
    if [[ -x ${WALKER_VPN_LINK_OPENER:-} ]]; then
        # Some applications use the desktop opener's absolute path.
        # This bind is visible only in the app's private mount namespace.
        mount --bind "$WALKER_VPN_LINK_OPENER" "$WALKER_VPN_DESKTOP_OPENER" || exit 1
        user_path=/usr/local/bin:/usr/bin:/bin
        for setting in "${session[@]}"; do
            if [[ $setting == PATH=* ]]; then user_path=${setting#PATH=}; break; fi
        done
        session+=("PATH=${WALKER_VPN_LINK_OPENER%/*}:$user_path" "BROWSER=$WALKER_VPN_LINK_OPENER")
    fi
    set -- /usr/bin/bash "${BASH_SOURCE[0]%/*}/app-session.sh" \
        "$(command -v xdg-dbus-proxy)" "$(command -v dbus-run-session)" "$namespace" "$app_id" "$@"
fi

cd "$home" || exit 1
printf 'READY\n'
exec setpriv --reuid="$uid" --regid="$gid" --init-groups --no-new-privs -- \
    env -i HOME="$home" USER="$user" LOGNAME="$user" XDG_RUNTIME_DIR="$runtime" \
    DBUS_SESSION_BUS_ADDRESS="$session_bus" \
    DBUS_SYSTEM_BUS_ADDRESS=unix:path=/dev/null \
    PATH=/usr/local/bin:/usr/bin:/bin "${session[@]}" "$@"
