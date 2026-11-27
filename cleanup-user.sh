#!/usr/bin/env bash
set -euo pipefail
(( EUID != 0 )) || exit 2
client=/usr/local/bin/walker-vpn
# Do not remove a working fallback unless the replacement is ready.
"$client" status | jq -e 'has("connection") and has("login")' >/dev/null
installed=${XDG_DATA_HOME:-$HOME/.local/share}/plasma/plasmoids/local.pia.wireguard.routing/contents/ui/main.qml
grep -Fq 'readonly property string helper: "/usr/local/bin/walker-vpn"' "$installed" || {
    echo 'Upgrade the panel to the system helper before removing the old directory.' >&2
    exit 1
}
data=${XDG_DATA_HOME:-$HOME/.local/share}
state=${XDG_STATE_HOME:-$HOME/.local/state}/walker-vpn
# Keep the completed migration snapshot with the current state, rather than
# retaining a second legacy configuration tree.
legacy=$HOME/.config/pia-wireguard
if [[ -f $legacy/apps.json ]]; then
    echo 'Pending legacy routing settings must be migrated before cleanup.' >&2
    exit 1
fi
if [[ -f $legacy/apps.json.pre-bash-backend ]]; then
    mkdir -p "$state"
    if [[ ! -f $state/legacy-migration.completed.json ]]; then
        install -m 0600 "$legacy/apps.json.pre-bash-backend" "$state/legacy-migration.completed.json"
    fi
    if cmp -s "$legacy/apps.json.pre-bash-backend" "$state/legacy-migration.completed.json"; then
        rm -- "$legacy/apps.json.pre-bash-backend"
    fi
fi
rm -f -- "$legacy/apps.lock"
rmdir "$legacy" 2>/dev/null || :
# Only empty Vopono config directories are removed; unrelated profiles stay.
rmdir "$HOME/.config/vopono/locks" "$HOME/.config/vopono" 2>/dev/null || :
rm -f -- "$HOME/.local/bin/vopono"
rm -f -- "${XDG_RUNTIME_DIR:-/run/user/$UID}/pia-desktop.lock" "${XDG_RUNTIME_DIR:-/run/user/$UID}/pia-desktop.json"
rm -rf -- "$data/pia-vopono"
rm -f -- "$data/applications/pia-vopono-credentials.desktop" "$data/applications/pia-vopono-qbittorrent.desktop"
mkdir -p "$data/applications"
cat > "$data/applications/pia-wireguard-credentials.desktop" <<'ENTRY'
[Desktop Entry]
Type=Application
Name=PIA VPN Credentials
Comment=Update the PIA login stored by the WireGuard backend
Exec=/usr/local/bin/walker-vpn credentials
Icon=wallet-open
Terminal=false
Categories=Network;
ENTRY
if command -v update-desktop-database >/dev/null; then update-desktop-database "$data/applications"; fi
if command -v kbuildsycoca6 >/dev/null; then kbuildsycoca6 --noincremental >/dev/null 2>&1; fi
printf '%s\n' 'Retired PIA user backend and broken shortcuts removed.'
