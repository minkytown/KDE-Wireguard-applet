# Run as the desktop user, inside the app network namespace.
set -uo pipefail
proxy=$1 dbus_session=$2 namespace=$3 app_id=$4
shift 4
[[ $namespace =~ ^wv[0-9a-f]{10}$ ]] || exit 1
private=$XDG_RUNTIME_DIR/walker-vpn-private-$namespace
if [[ -S $private/bus ]]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$private/bus"
    exec "$@"
fi
if [[ ! -S $XDG_RUNTIME_DIR/bus ]]; then
    unset DBUS_SESSION_BUS_ADDRESS
    exec "$@"
fi
if [[ ! -x $proxy ]]; then
    printf 'The filtered desktop session bus proxy is unavailable.\n' >&2
    exit 1
fi

directory=$(mktemp -d "$XDG_RUNTIME_DIR/walker-vpn-bus.XXXXXXXX") || exit 1
socket=$directory/bus
child= proxy_pid= logger_pid= owns_private=false
stop_proxy() {
    if [[ -n $proxy_pid ]]; then
        kill -TERM "$proxy_pid" 2>/dev/null || :
        wait "$proxy_pid" 2>/dev/null || :
        proxy_pid=
    elif [[ -n $logger_pid ]]; then
        kill -TERM "$logger_pid" 2>/dev/null || :
    fi
    if [[ -n $logger_pid ]]; then
        wait "$logger_pid" 2>/dev/null || :
        logger_pid=
    fi
}
cleanup() {
    if [[ -n $child ]]; then kill -TERM "$child" 2>/dev/null || :; fi
    stop_proxy
    if [[ $owns_private == true ]]; then rm -rf -- "$private"; fi
    rm -rf -- "$directory"
}
trap cleanup EXIT
trap 'exit 143' TERM HUP INT

mkfifo "$directory/ready" "$directory/events" || exit 1
exec {ready}<>"$directory/ready" || exit 1
exec {input}<&0
(
    if ! IFS= read -r -N 1 -t 3 -u "$ready"; then
        printf 'The filtered desktop session bus did not start.\n' >&2
        exit 1
    fi
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$socket"
    exec {input}<&- {ready}>&-
    exec "$@"
) <&"$input" &
child=$!
exec {input}<&-
rules=(
    --filter
    --talk=org.kde.StatusNotifierWatcher
    --talk=org.freedesktop.Notifications
    '--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.Settings.*@/org/freedesktop/portal/desktop'
    '--broadcast=org.freedesktop.portal.Desktop=org.freedesktop.portal.Settings.SettingChanged@/org/freedesktop/portal/desktop'
)
if [[ $app_id =~ ^[a-zA-Z_][a-zA-Z0-9_-]*(\.[a-zA-Z_][a-zA-Z0-9_-]*)+$ ]]; then
    rules+=("--own=$app_id")
fi
for instance in {1..4}; do
    rules+=("--own=org.kde.StatusNotifierItem-$child-$instance")
done
# Keep only the timestamp of a denied ownership request.
awk '/^Filtering message due to arg0 .*policy: [0-2] [(]required 3[)]$/ {
    print systime() > denied; close(denied)
}' denied="$directory/own-denied" < "$directory/events" &
logger_pid=$!
stdbuf -oL "$proxy" "--fd=$ready" "unix:path=$XDG_RUNTIME_DIR/bus" "$socket" "${rules[@]}" --log </dev/null > "$directory/events" &
proxy_pid=$!
exec {ready}>&-
result=0
wait "$child" || result=$?
child=
stop_proxy
denied=0
if [[ -s $directory/own-denied ]]; then denied=$(< "$directory/own-denied"); fi
if [[ $denied =~ ^[1-9][0-9]*$ && -x $dbus_session ]] && (( result != 0 && EPOCHSECONDS - denied <= 5 )); then
    # Give internal helpers their own bus without granting access to host services.
    if mkdir -m 700 -- "$private" 2>/dev/null; then
        owns_private=true
        cat >"$private/config" <<CONFIG
<busconfig>
  <type>session</type>
  <listen>unix:path=$private/bus</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow own="*"/>
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
  </policy>
</busconfig>
CONFIG
        "$dbus_session" --config-file="$private/config" -- "$@" <&0 &
        child=$!
        wait "$child"
        result=$?
        child=
        exit "$result"
    fi
    for (( attempt=0; attempt<30; attempt++ )); do
        if [[ -S $private/bus ]]; then
            export DBUS_SESSION_BUS_ADDRESS="unix:path=$private/bus"
            "$@" <&0 &
            child=$!
            wait "$child"
            result=$?
            child=
            exit "$result"
        fi
        sleep .1
    done
fi
exit "$result"
