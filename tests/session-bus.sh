#!/usr/bin/env bash
set -euo pipefail
lib=$(cd -- "${BASH_SOURCE[0]%/*}/../lib" && pwd)
proxy=${WALKER_VPN_TEST_PROXY:-$(command -v xdg-dbus-proxy || :)}
if [[ ! -x $proxy ]]; then
    echo 'Set WALKER_VPN_TEST_PROXY or add xdg-dbus-proxy to PATH.'
    exit 1
fi
scratch=$(mktemp -d)
bus_pid=
trap 'if [[ -n $bus_pid ]]; then kill "$bus_pid"; fi; rm -rf -- "$scratch"' EXIT
export XDG_RUNTIME_DIR=$scratch
bus_pid=$(dbus-daemon --session --address="unix:path=$scratch/bus" --fork --print-pid)
export attempts=$scratch/attempts
namespace=wv0123456789
bash "$lib/app-session.sh" "$proxy" "$(command -v dbus-run-session)" "$namespace" org.example.App \
    bash -c '
        printf "%s\n" "$DBUS_SESSION_BUS_ADDRESS" >> "$attempts"
        busctl --address="$DBUS_SESSION_BUS_ADDRESS" call org.freedesktop.DBus \
            /org/freedesktop/DBus org.freedesktop.DBus RequestName su org.example.Worker 0
    ' > "$scratch/result" 2> "$scratch/errors"
mapfile -t addresses < "$attempts"
[[ ${#addresses[@]} == 2 && ${addresses[0]} == *walker-vpn-bus.* && ${addresses[1]} == *walker-vpn-private-$namespace/bus,* ]]
rg -Fxq 'u 1' "$scratch/result"
[[ ! -e $scratch/walker-vpn-private-$namespace ]]
echo 'A denied internal service name retried on a private bus and left no session socket behind.'

: > "$attempts"
if bash "$lib/app-session.sh" "$proxy" "$(command -v dbus-run-session)" "$namespace" org.example.App \
    bash -c 'printf "%s\n" "$DBUS_SESSION_BUS_ADDRESS" >> "$attempts"; exit 4'; then
    exit 1
else
    [[ $? == 4 ]]
fi
[[ $(wc -l < "$attempts") == 1 ]]
echo 'An unrelated startup failure preserved the original exit code without a retry.'

: > "$attempts"
bash "$lib/app-session.sh" "$proxy" "$(command -v dbus-run-session)" "$namespace" org.example.App \
    bash -c '
        printf "%s\n" "$DBUS_SESSION_BUS_ADDRESS" >> "$attempts"
        busctl --address="$DBUS_SESSION_BUS_ADDRESS" call org.freedesktop.DBus \
            /org/freedesktop/DBus org.freedesktop.DBus RequestName su org.example.Worker 0 || :
    ' > /dev/null 2>&1
[[ $(wc -l < "$attempts") == 1 ]]
echo 'A successful app is never relaunched after a bus denial.'
