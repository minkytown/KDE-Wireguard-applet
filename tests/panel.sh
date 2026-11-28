#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export XDG_STATE_HOME=$scratch/state XDG_DATA_HOME=$scratch/data XDG_DATA_DIRS=$scratch/system
source "$root/lib/desktop.sh"
source "$root/lib/panel.sh"
mkdir -p "$XDG_DATA_DIRS/applications" "$desktop_root/org.example.One.desktop"
cat > "$XDG_DATA_DIRS/applications/org.example.One.desktop" <<'ENTRY'
[Desktop Entry]
Name=One 'quoted'
Icon=example
Exec=example %U
ENTRY
printf 'vpn\n' > "$desktop_root/org.example.One.desktop/mode"
printf 'uk\n' > "$desktop_root/org.example.One.desktop/region"
result=$(panel_command app-list-json)
jq -e '.apps[] | select(.id == "org.example.One.desktop") | .required and (.region == "uk")' <<< "$result" >/dev/null
request() {
    if [[ $1 == locations ]]; then printf '[]\n'; else printf '%s\n' '{"connection":"reconnecting","region":"uk","kill":"degraded","bootReconnect":"On"}'; fi
}
read_status() { request status; }
panel_command panel-status | jq -e '.connection=="Reconnecting · uk" and .killSwitch=="Degraded" and .bootReconnect=="On"' >/dev/null
panel_command locations-json | jq -e '.[0].id=="optimal"' >/dev/null
install_desktop() { [[ $* == 'org.example.One.desktop vpn optimal' ]]; }
panel_command app-set-json org.example.One.desktop on --mode vpn optimal | jq -e '.apps|length>0' >/dev/null
if panel_command app-set-json '../escape.desktop' on --mode vpn; then exit 1; fi
if panel_command system-connect --region 'bad;command'; then exit 1; fi
install_desktop() { return 1; }
panel_command app-set-json org.example.One.desktop on --mode direct | jq -e '.error|length>0' >/dev/null
install_desktop() { return 2; }
panel_command app-set-json org.example.One.desktop on --mode direct | jq -e '.cancelled and (.error|contains("unchanged")) and (.apps[0].required == true)' >/dev/null
printf 'Panel status, routing locations, failures and input validation passed.\n'
