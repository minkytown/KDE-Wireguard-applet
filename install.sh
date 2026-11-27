#!/usr/bin/env bash
set -euo pipefail
if (( EUID == 0 || $# != 0 )); then
    echo 'Run ./install.sh as the Plasma desktop user.' >&2
    exit 2
fi
bundle=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
for command in sudo kpackagetool6 kdialog curl flatpak ip wg wg-quick nft resolvectl systemctl setpriv mount jq socat grep gawk xdg-dbus-proxy dbus-daemon systemd-creds gio notify-send; do
    command -v "$command" >/dev/null || { echo "Missing dependency: $command" >&2; exit 1; }
done
systemctl is-active --quiet systemd-resolved.service || { echo 'systemd-resolved must be active.' >&2; exit 1; }
# Verify everything before changing launchers or services.
if [[ -f $HOME/.config/pia-wireguard/apps.json ]]; then
    bash "$bundle/migrate-legacy.sh" --check
fi
if [[ -f $HOME/.config/pia-wireguard/apps.json ]]; then
    while IFS= read -r id; do
        if flatpak ps --columns=application | grep -Fxq "$id"; then
            echo "Quit $id before upgrading its VPN routing." >&2
            exit 1
        fi
    done < <(jq -r 'keys[]' "$HOME/.config/pia-wireguard/apps.json")
fi
if [[ -n ${SUDO_ASKPASS:-} ]]; then sudo -A -v; else sudo -v; fi
bash "$bundle/migrate-legacy.sh" --restore
sudo -- /usr/bin/bash "$bundle/system/install" "$bundle" "$USER"
destination="$HOME/.local/share/pia-vopono"
install -d -m 0755 "$destination/bin" "$destination/lib"
install -m 0755 "$bundle/bin/"* "$destination/bin/"
install -m 0644 "$bundle/lib/"* "$destination/lib/"
# The helper path and applet ID stay stable on existing panels.
id=local.pia.wireguard.routing
if kpackagetool6 --type Plasma/Applet --show "$id" >/dev/null 2>&1; then
    kpackagetool6 --type Plasma/Applet --upgrade "$bundle/plasmoid"
else
    kpackagetool6 --type Plasma/Applet --install "$bundle/plasmoid"
fi
install -d "$HOME/.config/systemd/user" "$HOME/.config/plasma-workspace/env"
install -m 0644 "$bundle/system/user/"* "$HOME/.config/systemd/user/"
cat > "$HOME/.config/plasma-workspace/env/pia-routing.sh" <<'ENV'
export PATH="$HOME/.local/state/walker-vpn/apps/bin:/usr/local/bin:$PATH"
ENV
systemctl --user daemon-reload
systemctl --user enable --now walker-vpn-links.socket
bash "$bundle/migrate-legacy.sh" --apply
# Retire only the old implementation files after successful migration.
rm -f -- "$destination/pia-vopono" "$destination/pia_apps.py" "$destination/pia-ca.crt"
if [[ -d $destination/__pycache__ ]]; then rm -rf -- "$destination/__pycache__"; fi
# Import an existing wallet login through a pipe. The secret never enters argv.
if command -v kwallet-query >/dev/null && command -v qdbus-qt6 >/dev/null; then
    wallet=$(qdbus-qt6 org.kde.kwalletd6 /modules/kwalletd6 org.kde.KWallet.networkWallet 2>/dev/null) || wallet=
    if [[ -n $wallet ]]; then
        if kwallet-query -r 'PIA VPN login' -f 'PIA WireGuard Apps' "$wallet" 2>/dev/null |
            jq -ec '{action:"login",provider:"pia",username:.[0],password:.[1]}' |
            socat -t 115 -T 117 - UNIX-CONNECT:/run/walker-vpn.sock |
            jq -e 'has("error") | not' >/dev/null; then
            echo 'Existing PIA wallet login imported and encrypted for the Bash backend.'
        else
            echo 'Use PIA Credentials… to save your login for the new backend.'
        fi
    fi
fi
printf '%s\n' 'Panel VPN upgraded.'
printf '%s\n' 'Existing panel widgets keep their position. Sign out and in to update native command routing in the desktop session.'
