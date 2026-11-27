#!/usr/bin/env bash
set -euo pipefail

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export XDG_DATA_HOME=$scratch/data XDG_STATE_HOME=$scratch/state
source "${BASH_SOURCE[0]%/*}/../lib/desktop.sh"

app=org.example.App
record=$desktop_root/$app.desktop
mkdir -p "$record"
printf '%s\n' flatpak > "$record/kind"
printf '%s\n' old-cached-command > "$record/command"

flatpak() {
    [[ $* == "info --show-metadata $app" ]]
    cat "$scratch/metadata"
}
app_closed() { return 0; }
gdbus() { return 0; }
notify() { printf '%s\n' "$*" >&2; }
run_protected() { printf '%s\n' "$@" > "$scratch/launch"; }

for mode in vpn direct; do
    printf '%s\n' "$mode" > "$record/mode"
    for executable in original-command updated-command; do
        printf '[Application]\ncommand=%s\n' "$executable" > "$scratch/metadata"
        desktop_launch "$app.desktop" -- 'two words'
        mapfile -t launch < "$scratch/launch"
        [[ ${#launch[@]} == 5 && ${launch[0]} == "$mode" && ${launch[1]} == flatpak &&
            ${launch[2]} == "$app" && ${launch[3]} == "$executable" && ${launch[4]} == 'two words' ]]
    done
done

rm -- "$scratch/launch"
printf '[Runtime]\ncommand=wrong-section\n' > "$scratch/metadata"
if desktop_launch "$app.desktop" -- 2>/dev/null || [[ -e $scratch/launch ]]; then
    exit 1
fi
printf 'Flatpak updates preserve both routing modes and use the new executable.\n'

# Simulate an older Flatpak export retained by the launcher index.
id=$app.desktop
exports=$desktop_data/flatpak/exports/share/applications
mkdir -p "$exports" "$desktop_data/applications"
printf '[Desktop Entry]\nName=Example App\nExec=flatpak run --arch=x86_64 --branch=stable --command=updated-command --file-forwarding %s @@u %%U @@\n' "$app" > "$exports/$id"
printf '[Application]\ncommand=updated-command\n' > "$scratch/metadata"
printf 'vpn\n' > "$record/mode"
flatpak() {
    if [[ $* == "info --show-metadata $app" ]]; then
        if [[ -e $scratch/replacing ]]; then rm "$scratch/replacing"; return 1; fi
        cat "$scratch/metadata"
    elif [[ $* == "info --show-ref $app" ]]; then
        printf 'app/%s/x86_64/stable\n' "$app"
    elif [[ $* == "override --user --unshare=network $app" ]]; then
        : > "$scratch/override"
    else
        return 1
    fi
}
refresh_desktop_launchers() { printf 'refresh\n' >> "$scratch/refresh"; }
notify() { printf '%s\n' "$*" >> "$scratch/notice"; }
WALKER_VPN_FLATPAK=/bin/false
uri='https://example.invalid/?first=a&second=b'
args=(run --arch=x86_64 --branch=stable --command=old-command --file-forwarding "$app" @@u "$uri" @@)
flatpak_command "${args[@]}"
mapfile -t launch < "$scratch/launch"
[[ ${#launch[@]} == 5 && ${launch[0]} == vpn && ${launch[3]} == updated-command && ${launch[4]} == "$uri" ]]
[[ -e $scratch/override && ! -e $scratch/notice ]]
rg -Fq "Exec=walker-vpn desktop $id --" "$desktop_data/applications/$id"
flatpak_command "${args[@]}"
[[ $(wc -l < "$scratch/refresh") == 1 ]]
gdbus() {
    if [[ ! -e $scratch/session ]]; then touch "$scratch/session"; return 1; fi
    return 0
}
touch "$scratch/replacing"
flatpak_command run --arch x86_64 --branch stable "$app" --start
[[ -e $scratch/session && ! -e $scratch/replacing && ! -e $scratch/notice ]]
rm "$scratch/launch"
if flatpak_command run --branch experimental "$app"; then exit 1; fi
[[ -s $scratch/notice && ! -e $scratch/launch ]]
rm "$scratch/notice"
printf 'Version=1.0\n' >> "$exports/$id"
flatpak_command run "$app"
[[ $(wc -l < "$scratch/refresh") == 2 && ! -e $scratch/notice ]]
rm "$scratch/launch"
if flatpak_command run --share=network "$app"; then exit 1; fi
[[ -s $scratch/notice && ! -e $scratch/launch ]]
printf 'A cached export repairs the launcher, refreshes once, and opens the current executable under its saved route. Unsupported options fail closed.\n'

# A secondary export may change while the main export stays identical.
settings=org.example.Settings.desktop
shortcut=$record/shortcuts/$settings
mkdir -p "$shortcut"
printf '[Desktop Entry]\nName=Settings\nExec=flatpak run --command=settings-old %s --settings\n' "$app" > "$exports/$settings"
render_desktop "$exports/$settings" "$id" flatpak true > "$shortcut/generated"
cp "$shortcut/generated" "$desktop_data/applications/$settings"
flatpak_command run "$app"
sed -i 's/settings-old/settings-new/' "$exports/$settings"
flatpak_command run "$app"
rg -Fq -- '--flatpak-command settings-new -- --settings' "$desktop_data/applications/$settings"
flatpak_command run --command=settings-new --file-forwarding "$app" @@u "$uri" @@
mapfile -t launch < "$scratch/launch"
[[ ${launch[3]} == settings-new && ${launch[4]} == "$uri" ]]
printf 'A secondary export refreshes independently and preserves its command during file forwarding.\n'
