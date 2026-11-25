#!/usr/bin/bash
set -euo pipefail

if (( EUID == 0 || $# != 1 )); then
    echo "Run as the Plasma user: ./install.sh /path/to/vopono" >&2
    exit 2
fi
bundle=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
vopono=$(realpath -e -- "$1")
if [[ ! -f $vopono || ! -x $vopono ]]; then
    echo "Select an executable Vopono binary." >&2
    exit 2
fi

for command in sudo kpackagetool6 kdialog curl flatpak ip wg wg-quick nft resolvectl systemctl setpriv mount; do
    command -v "$command" >/dev/null || { echo "Missing dependency: $command" >&2; exit 1; }
done
/usr/bin/python3 - <<'PY'
import ctypes
import dbus
import gi

gi.require_version("GioUnix", "2.0")
from gi.repository import GioUnix

libc = ctypes.CDLL(None)
if not all(hasattr(libc, name) for name in ("open_tree", "move_mount")):
    raise SystemExit("This glibc lacks the mount APIs required for Flatpak isolation.")
PY

systemctl is-active --quiet systemd-resolved.service || {
    echo "The systemd-resolved service must be active." >&2
    exit 1
}
help=$("$vopono" exec --help)
for option in --create-netns-only --custom-netns-name --firewall; do
    if [[ $help != *"$option"* ]]; then
        echo "This Vopono build lacks $option." >&2
        exit 1
    fi
done

destination="$HOME/.local/share/pia-vopono"
install -d -m 0755 "$destination"
install -m 0755 "$bundle/pia-vopono" "$destination/"
install -m 0644 "$bundle/pia_apps.py" "$bundle/pia-ca.crt" "$destination/"
id=local.pia.wireguard.routing
if kpackagetool6 --type Plasma/Applet --show "$id" >/dev/null 2>&1; then
    kpackagetool6 --type Plasma/Applet --upgrade "$bundle/plasmoid"
else
    kpackagetool6 --type Plasma/Applet --install "$bundle/plasmoid"
fi
sudo -- /usr/bin/bash "$bundle/guard/install" "$bundle" "$vopono" "$UID"
echo "Add the KDE Wireguard applet using Plasma’s Add Widgets menu."
