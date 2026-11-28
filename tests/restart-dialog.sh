#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)
scratch=$(mktemp -d)
fixture_pid=
trap 'if [[ -n $fixture_pid ]]; then kill "$fixture_pid" 2>/dev/null || :; wait "$fixture_pid" 2>/dev/null || :; fi; rm -rf "$scratch"' EXIT
export XDG_DATA_HOME=$scratch/data XDG_STATE_HOME=$scratch/state XDG_DATA_DIRS=$scratch/system
source "$root/lib/desktop.sh"
# Exercise the real KDialog adapter while keeping the fixture unattended.
source <(sed -n '/^choose() {/,/^}/p' "$root/bin/walker-vpn")
dialog_reply=1
kdialog() {
    [[ $1 == --title && $2 == 'Change app routing' && $3 == --warningyesno ]]
    [[ $4 == *'Save your work first.'* && $4 == *'Cancel keeps its current route.'* ]]
    [[ $5 == --yes-label && $6 == 'Close and reopen app' && $7 == --no-label && $8 == Cancel ]]
    return "$dialog_reply"
}
notify() { printf '%s\n' "$*" >> "$scratch/notifications"; }
refresh_desktop_launchers() { :; }
app_windows() { :; }
app_processes() {
    if [[ -n $fixture_pid ]] && kill -0 "$fixture_pid" 2>/dev/null; then printf '%s\n' "$fixture_pid"; fi
}
id=org.example.Restart.desktop
mkdir -p "$XDG_DATA_DIRS/applications"
printf '[Desktop Entry]\nType=Application\nName=Restart fixture\nExec=sleep 60\n' > "$XDG_DATA_DIRS/applications/$id"
gio() {
    [[ $1 == launch && -f $2 && $(< "$desktop_root/$id/mode") == vpn ]]
    ! kill -0 "$fixture_pid" 2>/dev/null
    flock -xn "$desktop_root/locks/$id" true
    flock -xn "$desktop_root/.lock" true
    printf 'reopened\n' > "$scratch/reopened"
}
sleep 60 &
fixture_pid=$!
# Cancel must leave the running process, launcher and policy untouched.
code=0
install_desktop "$id" vpn || code=$?
[[ $code == 2 && ! -f $desktop_root/$id/mode && ! -f $scratch/reopened ]]
kill -0 "$fixture_pid"
# Accept must wait for real process exit, save the route, then release locks
# before relaunching. Only this disposable sleep process receives SIGTERM.
dialog_reply=0
install_desktop "$id" vpn
wait "$fixture_pid" 2>/dev/null || :
[[ $(< "$scratch/reopened") == reopened && $(< "$desktop_root/$id/mode") == vpn ]]
fixture_pid=
printf 'KDialog cancel preserves a live app and its policy; acceptance closes it before changing and reopening under the new route.\n'
# If closure fails, the timeout must retain the old route and not reopen.
sleep 60 &
fixture_pid=$!
rm "$scratch/reopened"
(
    kill() {
        if [[ $1 == -TERM ]]; then return 0; fi
        builtin kill "$@"
    }
    sleep() { SECONDS=$(( SECONDS + 16 )); }
    code=0
    install_desktop "$id" direct || code=$?
    [[ $code == 1 && $(< "$desktop_root/$id/mode") == vpn && ! -f $scratch/reopened ]]
)
kill -0 "$fixture_pid"
printf 'An app that cannot close keeps its previous route and is not reopened.\n'
