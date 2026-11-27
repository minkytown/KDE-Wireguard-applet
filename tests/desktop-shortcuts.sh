#!/usr/bin/env bash
set -euo pipefail
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export XDG_DATA_HOME=$scratch/data XDG_STATE_HOME=$scratch/state XDG_DATA_DIRS=$scratch/system
source "${BASH_SOURCE[0]%/*}/../lib/desktop.sh"
mkdir -p "$XDG_DATA_DIRS/applications" "$scratch/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$scratch/bin/example-client"
chmod +x "$scratch/bin/example-client"
PATH="$scratch/bin:$PATH"
id=org.example.Client.desktop
settings=org.example.Settings.desktop
cat > "$XDG_DATA_DIRS/applications/$id" <<'ENTRY'
[Desktop Entry]
Name=Example Client
Exec=example-client %U
MimeType=x-scheme-handler/magnet;
DBusActivatable=true
Actions=NewWindow;

[Desktop Action NewWindow]
Name=New Window
Exec=example-client --new-window %U
ENTRY
printf '[Desktop Entry]\nName=Example Settings\nExec=example-client --settings\n' > "$XDG_DATA_DIRS/applications/$settings"
app_processes() {
    if [[ -f $scratch/running ]]; then printf '9999999\n'; fi
}
choose() {
    [[ $2 == 'Close and reopen app' && $3 == Cancel ]]
    if [[ -f $scratch/cancel ]]; then printf '1\n'; return; fi
    rm "$scratch/running"
    printf '0\n'
}
gio() {
    [[ $1 == launch && -f $2 ]]
    flock -xn "$desktop_root/locks/$id" true
    flock -xn "$desktop_root/.lock" true
    printf '%s\n' "$2" >> "$scratch/reopened"
}
refresh_desktop_launchers() { printf 'refresh\n' >> "$scratch/refresh"; }
touch "$scratch/running" "$scratch/cancel"
if install_desktop "$id" vpn; then exit 1; fi
[[ ! -e $scratch/reopened && ! -e $desktop_root/$id/mode ]]
rm "$scratch/cancel"
install_desktop "$id" vpn
main=$desktop_data/applications/$id
alternate=$desktop_data/applications/$settings
rg -Fxq "Exec=walker-vpn desktop $id -- example-client %U" "$main"
rg -Fxq "Exec=walker-vpn desktop $id -- example-client --new-window %U" "$main"
rg -Fxq 'MimeType=x-scheme-handler/magnet;' "$main"
rg -Fxq "Exec=walker-vpn desktop $id -- example-client --settings" "$alternate"
touch "$scratch/running"
install_desktop "$settings" direct
[[ $(< "$desktop_root/$id/mode") == direct && ! -e $desktop_root/$settings/mode ]]
touch "$scratch/running"
install_desktop "$settings" default
[[ ! -e $main && ! -e $alternate ]]
[[ $(wc -l < "$scratch/refresh") == 3 ]]
mapfile -t reopened < "$scratch/reopened"
[[ ${#reopened[@]} == 3 ]]
[[ ${reopened[0]} == "$main" && ${reopened[1]} == "$alternate" &&
    ${reopened[2]} == "$XDG_DATA_DIRS/applications/$settings" ]]
printf 'Route changes reopen the selected launcher after releasing locks. Cancel leaves it alone.\n'

cat > "$scratch/flatpak" <<'ENTRY'
[Desktop Entry]
Exec=/usr/bin/flatpak run --branch=stable --command=example --file-forwarding org.example.Client @@u %U @@
Actions=Settings;

[Desktop Action Settings]
Exec=/usr/bin/flatpak run --command=example-settings org.example.Client --open
ENTRY
render_desktop "$scratch/flatpak" "$id" flatpak > "$scratch/generated"
rg -q "^Exec=walker-vpn desktop $id -- +%U *$" "$scratch/generated"
rg -Fxq "Exec=walker-vpn desktop $id --flatpak-command example-settings -- --open" "$scratch/generated"
printf 'Related launchers, actions, MIME handlers and Elephant refresh calls passed.\n'

# Old releases misclassified an exported Flatpak Settings shortcut as native.
primary=$XDG_DATA_DIRS/applications/$id
secondary=$XDG_DATA_DIRS/applications/$settings
cp "$scratch/flatpak" "$primary"
cat > "$secondary" <<'ENTRY'
[Desktop Entry]
Name=Example Settings
Exec=flatpak run --arch=x86_64 --branch=stable --command=settings org.example.Client --settings
X-Flatpak=org.example.Client
ENTRY
for key in "$id" "$settings"; do
    mkdir -p "$desktop_root/$key"
    printf 'vpn\n' > "$desktop_root/$key/mode"
done
printf 'flatpak\n' > "$desktop_root/$id/kind"
printf 'native\n' > "$desktop_root/$settings/kind"
mkdir -p "$desktop_data/applications"
cp "$scratch/generated" "$desktop_root/$id/generated"
cp "$scratch/generated" "$main"
printf 'Exec=walker-vpn desktop %s -- flatpak run org.example.Client --settings\n' "$settings" > "$alternate"
cp "$alternate" "$desktop_root/$settings/generated"
sync_saved_launchers
[[ ! -e $desktop_root/$settings/mode ]]
[[ $(shortcut_owner "$settings" "$alternate") == "$id" ]]
rg -Fxq "Exec=walker-vpn desktop $id --flatpak-command settings -- --settings" "$alternate"
install_desktop "$settings" default
[[ ! -e $main && ! -e $alternate ]]
printf 'Existing split Flatpak policies migrated to one route, with their Settings command intact.\n'
