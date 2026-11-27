# Both the desktop client and the privileged backend use this allowlist.
app_session_keys=(
    DISPLAY WAYLAND_DISPLAY XAUTHORITY LANG LC_ALL
    XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_SESSION_DESKTOP
    XDG_DATA_HOME XDG_DATA_DIRS XDG_CONFIG_HOME XDG_CONFIG_DIRS XDG_CACHE_HOME XDG_STATE_HOME
    QT_QPA_PLATFORM QT_QPA_PLATFORMTHEME QT_PLUGIN_PATH QT_STYLE_OVERRIDE
    QT_QPA_PLATFORM_PLUGIN_PATH QT_WAYLAND_RECONNECT QT_QUICK_CONTROLS_STYLE
    GTK_THEME GTK_PATH GDK_BACKEND GSETTINGS_SCHEMA_DIR XCURSOR_THEME XCURSOR_SIZE
    PIPEWIRE_REMOTE PULSE_SERVER PATH
)

read_desktop_timezone() {
    local localtime=$1 timezone_file=$2 target= directory zone=
    desktop_tzdir= desktop_tz=
    # Flatpak compares the immediate localtime symlink with TZDIR. Keep the
    # configured path even when the directory itself is a symlink.
    if target=$(readlink -- "$localtime"); then
        if [[ $target != /* ]]; then target=${localtime%/*}/$target; fi
        case $target in
            *//*|*/./*|*/../*) target=$(realpath --canonicalize-missing --no-symlinks -- "$target") || target= ;;
        esac
        if [[ $target == */zoneinfo/* ]]; then
            desktop_tzdir=${target%/zoneinfo/*}/zoneinfo
        elif [[ ${TZDIR:-} == /* && $target == "${TZDIR%/}/"* ]]; then
            desktop_tzdir=${TZDIR%/}
        fi
        if [[ -n $desktop_tzdir && -f $target ]]; then
            zone=${target#"$desktop_tzdir"/}
            if [[ $zone =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]]; then
                desktop_tz=$zone
                return
            fi
        fi
    fi
    desktop_tzdir= zone=
    if [[ -r $timezone_file ]]; then IFS= read -r zone < "$timezone_file" || :; fi
    for directory in "${TZDIR:-}" /etc/zoneinfo /usr/share/zoneinfo; do
        [[ $directory == /* && -d $directory ]] || continue
        if [[ -z $desktop_tzdir ]]; then desktop_tzdir=$directory; fi
        # A copied localtime can have a named zone, but /etc/timezone can be stale.
        if [[ $zone =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ && -f $directory/$zone ]] &&
            cmp -s -- "$localtime" "$directory/$zone"; then
            desktop_tzdir=$directory desktop_tz=$zone
            return
        fi
    done
}

# Hide the host resolver socket without hiding Bazzite's resolv.conf target.
# The caller has already entered the app's private network/mount namespaces.
isolate_host_resolver() {
    local target resolver
    [[ -d /run/systemd/resolve ]] || return 0
    target=$(readlink -f /etc/resolv.conf) || return 1
    resolver=$(cat /etc/resolv.conf) || return 1
    mount -t tmpfs -o size=64k,mode=755 tmpfs /run/systemd/resolve || return 1
    if [[ $target == /run/systemd/resolve/* ]]; then
        mkdir -p -- "${target%/*}" || return 1
        printf '%s\n' "$resolver" > "$target" || return 1
        chmod 644 "$target" || return 1
    fi
}
