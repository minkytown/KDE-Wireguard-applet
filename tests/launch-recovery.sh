#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)
source <(sed '/^case "\${1:-}" in/,$d' "$root/lib/service.sh") "$root/lib" example
set -e
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
run=$scratch/run state=$scratch/state profile=$scratch/profile
mkdir "$run" "$state"
tunnel_is_up() { [[ -e $run/up ]]; }
publish_status() { :; }
connect_host() {
    printf '%s\n' "$1" >> "$run/connect-attempts"
    [[ ! -e $run/fail ]] && touch "$run/up"
}
recover() { touch "$run/recovered" "$run/up"; }
if ensure_host_for_app >"$scratch/error" 2>/dev/null; then exit 1; fi
rg -q '^ERROR Save a PIA login' "$scratch/error"
printf 'fixture\n' > "$state/pia-login.cred"
printf 'saved-location\n' > "$state/last-host-region"
ensure_host_for_app
ensure_host_for_app
[[ $(wc -l < "$run/connect-attempts") == 1 && $(< "$run/connect-attempts") == saved-location ]]
[[ ! -e $run/pending-region ]]
rm "$run/up"
touch "$run/manual-disconnect"
if ensure_host_for_app >"$scratch/error" 2>/dev/null; then exit 1; fi
rg -q '^ERROR The host VPN was disconnected manually' "$scratch/error"
[[ $(wc -l < "$run/connect-attempts") == 1 ]]
rm "$run/manual-disconnect"
touch "$run/region" "$profile"
ensure_host_for_app
[[ -e $run/recovered && $(wc -l < "$run/connect-attempts") == 1 ]]
rm "$run/up" "$run/region" "$profile" "$state/last-host-region"
touch "$run/fail"
if ensure_host_for_app >"$scratch/error" 2>/dev/null; then exit 1; fi
[[ $(tail -1 "$run/connect-attempts") == optimal && ! -e $run/pending-region ]]
rg -q '^ERROR Could not restore the host VPN' "$scratch/error"

source "$root/lib/desktop.sh"
notify() { printf '%s\n' "$1" >> "$scratch/notice"; }
sleep() { :; }
run_protected() {
    printf '%s\n' "$*" >> "$scratch/attempts"
    if [[ $(wc -l < "$scratch/attempts") == 1 ]]; then
        printf 'RETRY\n' > "$launch_error_file"
        return 1
    fi
}
launch_desktop_protected vpn native org.example.Client client 'two words'
[[ $(wc -l < "$scratch/attempts") == 2 && ! -e $scratch/notice ]]
[[ $(sort -u "$scratch/attempts" | wc -l) == 1 ]]
run_protected() { printf 'ERROR Connect the host VPN first.\n' > "$launch_error_file"; return 1; }
if launch_desktop_protected vpn native org.example.Client client; then exit 1; fi
[[ $(< "$scratch/notice") == 'Connect the host VPN first.' ]]
printf 'Host recovery honors saved location and manual disconnect. Launch retries only a pre-start shutdown conflict.\n'

flatpak() {
    local attempts=0
    if [[ -f $scratch/flatpak-attempts ]]; then attempts=$(< "$scratch/flatpak-attempts"); fi
    (( ++attempts ))
    printf '%s\n' "$attempts" > "$scratch/flatpak-attempts"
    if [[ ${flatpak_teardown:-} == lasting || $attempts -lt 4 ]]; then
        printf 'org.example.Client\t54123\n'
    fi
}
ps() {
    if [[ ${flatpak_teardown:-} == live ]]; then printf '54123 1 S\n'; fi
}
app_closed org.example.Client.desktop flatpak "$scratch/placeholder"
[[ $(< "$scratch/flatpak-attempts") == 4 ]]
rm "$scratch/flatpak-attempts"
if flatpak_teardown=live app_closed org.example.Client.desktop flatpak "$scratch/placeholder"; then exit 1; fi
[[ $(< "$scratch/flatpak-attempts") == 1 ]]
rm "$scratch/flatpak-attempts"
if flatpak_teardown=lasting app_closed org.example.Client.desktop flatpak "$scratch/placeholder"; then exit 1; fi
[[ $(< "$scratch/flatpak-attempts") == 51 ]]
printf 'Flatpak launch waits for a stale teardown entry and still refuses a live app.\n'
