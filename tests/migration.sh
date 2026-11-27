#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export PIA_LEGACY_HOME=$scratch/home XDG_STATE_HOME=$scratch/state XDG_DATA_HOME=$scratch/data
mkdir -p "$PIA_LEGACY_HOME/.config/pia-wireguard" "$XDG_DATA_HOME/applications" "$XDG_DATA_HOME/flatpak/overrides" "$scratch/bin"
registry=$PIA_LEGACY_HOME/.config/pia-wireguard/apps.json
printf '[Desktop Entry]\nName=Original\nExec=original %%U\n' > "$scratch/original"
data=$(base64 -w0 "$scratch/original")
jq -nc --arg data "$data" '{"org.example.App": {kind:"Flatpak",mode:"direct",previous_network:"network",previous_launcher:{$data,mode:420}}}' > "$registry"
printf '[Desktop Entry]\nX-PIA-Protected-Launcher=true\nExec=old-client\n' > "$XDG_DATA_HOME/applications/org.example.App.desktop"
printf '[Context]\nshared=!network;ipc;\nsockets=wayland;\n' > "$XDG_DATA_HOME/flatpak/overrides/org.example.App"
bash "$root/migrate-legacy.sh" --check
bash "$root/migrate-legacy.sh" --restore
cmp "$scratch/original" "$XDG_DATA_HOME/applications/org.example.App.desktop"
rg -Fxq 'shared=ipc;network;' "$XDG_DATA_HOME/flatpak/overrides/org.example.App"
rg -Fxq 'sockets=wayland;' "$XDG_DATA_HOME/flatpak/overrides/org.example.App"
[[ ! -e $registry && -e $registry.pre-bash-backend ]]
cat > "$scratch/bin/walker-vpn" <<'MOCK'
#!/usr/bin/env bash
[[ $* == 'app-set-json org.example.App.desktop on --mode direct' ]] || exit 1
printf '{"apps":[]}\n'
MOCK
chmod +x "$scratch/bin/walker-vpn"
PATH="$scratch/bin:$PATH" bash "$root/migrate-legacy.sh" --apply
[[ -f $XDG_STATE_HOME/walker-vpn/legacy-migration.completed.json ]]
printf '{"../escape":{}}\n' > "$registry"
if bash "$root/migrate-legacy.sh" --check; then exit 1; fi
printf 'Legacy migration restores launcher bytes and unrelated Flatpak settings, reapplies routes, and rejects invalid IDs.\n'
