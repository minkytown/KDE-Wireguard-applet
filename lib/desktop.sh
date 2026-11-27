source "${BASH_SOURCE[0]%/*}/desktop-entry.sh"

desktop_data=${XDG_DATA_HOME:-$HOME/.local/share}
desktop_root=${XDG_STATE_HOME:-$HOME/.local/state}/walker-vpn/apps
command_dir=$desktop_root/bin

can_route_command() {
    [[ $1 =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.+-]{0,150}$ ]] || return 1
    case "$1" in
        bash|dash|sh|fish|env|node|electron|java|perl|ruby|python|python3|flatpak|walker-vpn|\
        systemctl|systemd-run|sudo|run0|setpriv|jq|socat|nft|ip|wg|mount|flock|awk|rg|\
        cat|sleep|readlink|stat|chmod|mv|rm|mkdir|ps|busctl|gdbus|hyprctl|walker) return 1 ;;
    esac
}

unrouted_path() {
    local directory result=
    local -a paths
    IFS=: read -ra paths <<< "$PATH"
    for directory in "${paths[@]}"; do
        [[ -n $directory && $directory != "$command_dir" ]] || continue
        result+="${result:+:}$directory"
    done
    printf '%s\n' "$result"
}

flatpak_command() {
    local argument candidate id command= cached=false unsupported=false forwarding=false export_command=
    local arch= branch= current_ref current_id current_arch current_branch
    local real=${WALKER_VPN_FLATPAK:?}
    local -a original=("$@")
    local -a options=()
    while [[ ${1:-} == -v || ${1:-} == --verbose || ${1:-} == --ostree-verbose ]]; do
        shift
    done
    if [[ ${1:-} == run ]]; then
        shift
        while (( $# )); do
            argument=$1
            shift
            case "$argument" in
                --arch|--branch|--command)
                    if (( $# )) && [[ $1 != -* ]]; then
                        argument+="=$1"
                        shift
                    else
                        unsupported=true
                        continue
                    fi
                    ;;
            esac
            case "$argument" in
                --arch=*)
                    arch=${argument#*=}
                    cached=true
                    continue
                    ;;
                --branch=*)
                    branch=${argument#*=}
                    cached=true
                    continue
                    ;;
                --command=*)
                    command=${argument#*=}
                    continue
                    ;;
                --file-forwarding)
                    forwarding=true
                    cached=true
                    continue
                    ;;
                --) continue ;;
                -*) unsupported=true; continue ;;
            esac
            candidate=${argument#app/}
            candidate=${candidate%%/*}
            if [[ ! $candidate =~ ^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+){2,}$ ]]; then
                unsupported=true
                continue
            fi
            id=$candidate.desktop
            if [[ -f $desktop_root/$id/mode && -f $desktop_root/$id/kind &&
                $(< "$desktop_root/$id/kind") == flatpak ]]; then
                if [[ $unsupported == true || ( -n $command && ! $command =~ ^[A-Za-z0-9_./][A-Za-z0-9_./+-]*$ ) ]]; then
                    notify 'Could not apply this Flatpak’s saved route to its launch options.'
                    return 1
                fi
                if [[ $argument != "$candidate" ]]; then
                    if [[ ${argument#app/} =~ ^[A-Za-z0-9_.-]+/([A-Za-z0-9_-]*)/([A-Za-z0-9_.-]+)$ ]]; then
                        arch=${BASH_REMATCH[1]}
                        branch=${BASH_REMATCH[2]}
                        cached=true
                    else
                        notify 'Could not apply this Flatpak’s saved route to that reference.'
                        return 1
                    fi
                fi
                # Exported desktop commands follow the installed deployment.
                # An explicit command-line selection must still match it.
                if [[ $forwarding == false && -z $command && ( -n $arch || -n $branch ) ]]; then
                    if ! current_ref=$(flatpak info --show-ref "$candidate"); then
                        notify 'Could not find the Flatpak’s installed deployment.'
                        return 1
                    fi
                    IFS=/ read -r _ current_id current_arch current_branch <<< "$current_ref"
                    if [[ $current_id != "$candidate" || ( -n $arch && $arch != "$current_arch" ) ||
                        ( -n $branch && $branch != "$current_branch" ) ]]; then
                        notify 'The requested Flatpak deployment differs from the one managed by the PIA applet.'
                        return 1
                    fi
                fi
                if [[ $forwarding == true ]]; then
                    # The main launcher follows the current deployment. A saved
                    # secondary shortcut can explicitly request another command.
                    if [[ -n $command ]] && ! flatpak_secondary_command "$id" "$command"; then command=; fi
                    local -a files=()
                    for argument; do
                        case "$argument" in @@|@@u) ;; *) files+=("$argument");; esac
                    done
                    set -- "${files[@]}"
                fi
                if [[ $cached == true && -n $command && -s $desktop_root/$id/export-command ]]; then
                    export_command=$(< "$desktop_root/$id/export-command")
                    if [[ $command == "$export_command" ]]; then command=; fi
                fi
                if [[ -n $command ]]; then options=(--flatpak-command "$command"); fi
                if [[ $forwarding == false ]]; then
                    WALKER_VPN_REFRESH_EXPORT=$cached WALKER_VPN_FLATPAK_OPTIONS=true \
                        desktop_launch "$id" "${options[@]}" -- "$@"
                else
                    WALKER_VPN_REFRESH_EXPORT=$cached desktop_launch "$id" "${options[@]}" -- "$@"
                fi
                return
            fi
            if [[ $unsupported == false ]]; then break; fi
        done
    fi
    exec "$real" "${original[@]}"
}

flatpak_secondary_command() {
    local id=$1 command=$2 record=$desktop_root/$1 entry
    for entry in "$record/generated" "$record/shortcuts/"*.desktop/generated; do
        [[ -f $entry ]] || continue
        if grep -qF "Exec=walker-vpn desktop $id --flatpak-command $command -- " "$entry"; then return 0; fi
    done
    return 1
}

app_processes() {
    local id=${1%.desktop} kind=$2 source=$3 running exec_line program resolved name
    local pid state comm argument scope own_scope response roots
    local -A names=() matches=()
    if [[ $kind == flatpak ]]; then
        running=$(flatpak ps --columns=application:f,child-pid) || return 2
        roots=$(awk -v id="$id" '$1==id { print ($2 ~ /^[1-9][0-9]+$/ ? $2 : 0) }' <<< "$running")
        [[ -n $roots ]] || return 0
        running=$(ps -u "$UID" -o pid=,ppid=,state=) || return 2
        # Include the actual app and any nested children under the sandbox PID.
        awk -v roots="$roots" '
            BEGIN {
                n=split(roots,lines,"\n")
                for(i=1;i<=n;i++) if (lines[i]>1) targets[lines[i]]=1
            }
            $3!="Z" { parent[$1]=$2 }
            END {
                for (pid in parent) {
                    p=pid
                    while (p>1 && !(p in targets) && (p in parent)) p=parent[p]
                    if (p in targets) {
                        print pid
                        found[p]=1
                    }
                }
                # Keep waiting if Flatpak lists an instance during teardown.
                for (p in targets) if (!(p in found)) missing=1
                if (missing || n!=length(targets)) print 0
            }
        ' <<< "$running"
        return 0
    fi

    exec_line=$(desktop_value "$source" Exec)
    exec_line=${exec_line#"walker-vpn desktop $1 -- "}
    program=$(desktop_executable "$exec_line") || program=
    case "${program##*/}" in
        bash|dash|sh|fish|node|electron|java|perl|ruby|python|python3) program= ;;
    esac
    resolved=$(type -P -- "$program") || resolved=
    for name in "$id" "${id##*.}" "${program##*/}" "$(desktop_value "$source" StartupWMClass)"; do
        [[ -n $name ]] && names[${name,,}]=1
    done
    if [[ $id == *.* && -n ${DBUS_SESSION_BUS_ADDRESS:-} ]] && command -v busctl >/dev/null; then
        response=$(busctl --user --timeout=1s call org.freedesktop.DBus /org/freedesktop/DBus \
            org.freedesktop.DBus GetConnectionUnixProcessID s "$id" 2>/dev/null) || response=
        if [[ $response =~ ^u\ ([1-9][0-9]+)$ && -O /proc/${BASH_REMATCH[1]} ]]; then
            matches[${BASH_REMATCH[1]}]=1
        fi
    fi

    IFS= read -r own_scope < /proc/self/cgroup || own_scope=
    running=$(ps -u "$UID" -o pid=,state=,comm=) || return 2
    while read -r pid state comm; do
        [[ -n $pid && $state != Z ]] || continue
        if [[ -n $resolved && /proc/$pid/exe -ef $resolved ]]; then matches[$pid]=1; continue; fi
        argument=
        { IFS= read -r -d '' argument < "/proc/$pid/cmdline"; } 2>/dev/null || :
        for name in "$comm" "${argument##*/}"; do
            name=${name#.}
            name=${name%-wrapped}
            if [[ -n $name && ${names[${name,,}]:-} ]]; then matches[$pid]=1; break; fi
        done
        if { IFS= read -r scope < "/proc/$pid/cgroup"; } 2>/dev/null &&
            [[ $scope != "$own_scope" && ( $scope == */app-"$id"-*.scope || $scope == */app-"$id"@*.service ) ]]; then
            matches[$pid]=1
        fi
    done <<< "$running"
    if (( ${#matches[@]} )); then printf '%s\n' "${!matches[@]}"; fi
}

app_closed() {
    local running attempt=0
    while :; do
        running=$(app_processes "$@") || return 2
        [[ -z $running ]] && return 0
        # Flatpak can list an instance after its last process has exited.
        # Wait for that entry to disappear without accepting a live process.
        [[ $2 == flatpak && $running == 0 ]] && (( attempt < 50 )) || return 1
        sleep .1
        (( ++attempt ))
    done
}

app_windows() {
    [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && command -v hyprctl >/dev/null || return 0
    local clients
    clients=$(hyprctl -j clients 2>/dev/null) || return 1
    jq -r --arg pids "$1" '($pids | split("\n") | map(tonumber)) as $targets |
        .[] | select(.pid as $pid | $targets | index($pid)) |
        .address | select(test("^0x[0-9a-fA-F]+$"))' <<< "$clients"
}

open_app_lock() {
    mkdir -p -- "$desktop_root/locks" &&
        exec {app_lock}>"$desktop_root/locks/$1"
}

close_app_before_change() {
    local id=$1 kind=$2 source=$3 name=$4 reopen_flag=${5:-} reply running windows pid address
    local deadline=0 requested_windows=false locked
    local -A signaled=()
    while :; do
        locked=false
        if flock -n "$app_lock"; then locked=true; fi
        running=$(app_processes "$id" "$kind" "$source") || {
            notify "Could not verify that $name is closed."
            return 2
        }
        if [[ $locked == true ]]; then
            if [[ -z $running ]]; then
                if (( deadline != 0 )) && [[ -n $reopen_flag ]]; then printf -v "$reopen_flag" true; fi
                return 0
            fi
            flock -u "$app_lock" || return 1
        fi
        if (( deadline == 0 )); then
            reply=$(choose "Reopen $name with its new VPN route? Save your work first" \
                'Close and reopen app' 'Cancel') || return 2
            [[ $reply == 0 ]] || return 2
            deadline=$(( SECONDS + 15 ))
            continue
        fi
        if (( SECONDS >= deadline )); then
            notify "$name is still running. Its VPN routing was not changed."
            return 2
        fi
        if [[ -n $running ]]; then
            windows=$(app_windows "$running") || {
                notify "Could not check $name's windows. Its VPN routing was not changed."
                return 2
            }
            if [[ -n $windows ]]; then
                if [[ $requested_windows == false ]]; then
                    while read -r address; do
                        hyprctl dispatch "hl.dsp.window.close({ window = [[address:$address]] })" >/dev/null 2>&1 ||
                            hyprctl dispatch closewindow "address:$address" >/dev/null 2>&1 || :
                    done <<< "$windows"
                    requested_windows=true
                fi
            else
                while read -r pid; do
                    [[ $pid =~ ^[1-9][0-9]+$ && -O /proc/$pid && ! ${signaled[$pid]:-} ]] || continue
                    kill -TERM "$pid" 2>/dev/null || :
                    signaled[$pid]=1
                done <<< "$running"
            fi
        fi
        sleep .25
    done
}

flatpak_network() {
    local id=$1 path=$desktop_data/flatpak/overrides/$1
    if [[ -f $path ]]; then
        awk '
            /^\[/ { ctx=($0=="[Context]") }
            ctx && /^shared=/ {
                count=split(substr($0,8), parts, ";")
                for (i=1; i<=count; i++) if (parts[i]=="network" || parts[i]=="!network") print parts[i]
            }
        ' "$path"
    fi
}

flatpak_executable() {
    local metadata attempt
    for attempt in 1 2 3; do
        if metadata=$(flatpak info --show-metadata "$1" 2>/dev/null); then break; fi
        if (( attempt == 3 )); then return 1; fi
        sleep .25
    done
    awk '
        /^\[/ { app=($0=="[Application]") }
        app && /^command=./ { print substr($0,9); found=1; exit }
        END { if (!found) exit 1 }
    ' <<< "$metadata"
}

prepare_flatpak_session() {
    local attempt
    for attempt in 1 2; do
        if gdbus call --session --timeout=3 --dest org.freedesktop.Flatpak \
            --object-path /org/freedesktop/Flatpak/SessionHelper \
            --method org.freedesktop.Flatpak.SessionHelper.RequestSession >/dev/null 2>&1; then
            return 0
        fi
        if (( attempt == 1 )); then sleep .25; fi
    done
    return 1
}

restore_network() {
    local id=$1 old=$2 path=$desktop_data/flatpak/overrides/$1 temporary
    [[ -f $path ]] || return 0
    temporary=$(mktemp "${path}.walker.XXXXXXXX") || return 1
    if ! awk -v old="$old" '
        /^\[/ { ctx=($0=="[Context]") }
        ctx && /^shared=/ {
            n=split(substr($0,8), parts, ";"); result=""
            for (i=1; i<=n; i++)
                if (parts[i]!="" && parts[i]!="network" && parts[i]!="!network")
                    result=result parts[i] ";"
            if (old!="") result=result old ";"
            if (result!="") print "shared=" result
            next
        }
        { print }
    ' "$path" > "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    mv -f -- "$temporary" "$path"
}

shortcut_owner() {
    local id=$1 file=$2 line linked ignored canonical
    line=$(desktop_value "$file" Exec)
    read -r ignored ignored linked ignored <<< "$line"
    if desktop_id "$linked" && [[ -f $desktop_root/$linked/shortcuts/$id/generated ]]; then
        printf '%s\n' "$linked"
    elif canonical=$(flatpak_desktop_app "${line#"walker-vpn desktop $id -- "}") && desktop_file "$canonical.desktop" >/dev/null; then
        printf '%s.desktop\n' "$canonical"
    else
        printf '%s\n' "$id"
    fi
}

refresh_desktop_launchers() {
    if command -v update-desktop-database >/dev/null; then
        update-desktop-database "$desktop_data/applications" || :
    fi
    if command -v kbuildsycoca6 >/dev/null; then
        kbuildsycoca6 --noincremental >/dev/null 2>&1 || :
    fi
    return 0
}

replace_launcher() (
    local source=$1 target=$2 temporary
    temporary=$(mktemp "${target%/*}/.walker.XXXXXXXX") || return 1
    trap 'rm -f -- "$temporary"' EXIT
    cp -- "$source" "$temporary" && mv -f -- "$temporary" "$target"
)

flatpak_export_desktop() {
    local file
    for file in "$desktop_data/flatpak/exports/share/applications/$1" \
                "/var/lib/flatpak/exports/share/applications/$1"; do
        if [[ -f $file ]]; then printf '%s\n' "$file"; return 0; fi
    done
    return 1
}

refresh_flatpak_entry() {
    local desktop=$1 owner=$2 record=$3 sibling=$4 source target rendered
    source=$(flatpak_export_desktop "$desktop") || return 0
    target=$desktop_data/applications/$desktop
    if [[ -f $target ]] && ! cmp -s "$target" "$record/generated" && ! cmp -s "$target" "$source"; then
        # Keep edits to the user's launcher separate from an upstream refresh.
        return 0
    fi
    if [[ -f $record/original ]]; then source=$record/original; fi
    rendered=$(mktemp "$record/.launcher.XXXXXXXX") || return 1
    if render_desktop "$source" "$owner" flatpak "$sibling" > "$rendered" &&
        replace_launcher "$rendered" "$target" && mv -f -- "$rendered" "$record/generated"; then
        return 0
    fi
    rm -f -- "$rendered"
    return 1
}

repair_flatpak_export() (
    local id=$1 record=$desktop_root/$1 export_file stamp edit shortcut exec_line secondary
    local refresh_cache=${WALKER_VPN_REFRESH_EXPORT:-false}
    export_file=$(flatpak_export_desktop "$id") || return 0
    local -a exports=("$export_file")
    for shortcut in "$record/shortcuts/"*.desktop; do
        [[ -f $shortcut/generated ]] || continue
        secondary=$(flatpak_export_desktop "${shortcut##*/}") || continue
        exports+=("$secondary")
    done
    stamp=$(stat -Lc '%d:%i:%s:%y' -- "${exports[@]}") || return 1
    if [[ -f $record/cache-stamp && $(< "$record/cache-stamp") == "$stamp" ]]; then refresh_cache=false; fi
    if [[ -f $record/export-stamp && $(< "$record/export-stamp") == "$stamp" &&
        -f $desktop_data/applications/$id && $refresh_cache == false ]]; then
        return 0
    fi
    exec {edit}>"$desktop_root/.lock"
    flock -w 5 "$edit" || return 1
    [[ -f $record/mode && -f $record/kind && $(< "$record/kind") == flatpak ]] || return 0
    if [[ ! -f $record/export-stamp || $(< "$record/export-stamp") != "$stamp" ||
        ! -f $desktop_data/applications/$id ]]; then
        mkdir -p -- "$desktop_data/applications" || return 1
        flatpak override --user --unshare=network "${id%.desktop}" || return 1
        refresh_flatpak_entry "$id" "$id" "$record" false || return 1
        for shortcut in "$record/shortcuts/"*.desktop; do
            [[ -f $shortcut/generated ]] || continue
            refresh_flatpak_entry "${shortcut##*/}" "$id" "$shortcut" true || return 1
        done
        exec_line=$(desktop_value "$export_file" Exec)
        if [[ $exec_line =~ [[:space:]]--command=([A-Za-z0-9_./+-]+) ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}" > "$record/export-command" || return 1
        fi
        printf '%s\n' "$stamp" > "$record/export-stamp" || return 1
    elif [[ $refresh_cache == false ||
        ( -f $record/cache-stamp && $(< "$record/cache-stamp") == "$stamp" ) ]]; then
        return 0
    fi
    refresh_desktop_launchers
    if [[ $refresh_cache == true ]]; then printf '%s\n' "$stamp" > "$record/cache-stamp"; fi
    return 0
)

sync_shortcuts() {
    local id=$1 source=$2 kind=$3 record=$desktop_root/$1 dir file alias target entry executable other
    local legacy mode line
    local PATH=$(unrouted_path)
    local -A seen=()
    local -a fields=()
    if [[ $kind == flatpak ]]; then
        executable=${id%.desktop}
    else
        executable=$(desktop_executable "$(desktop_value "$source" Exec)") || return 0
        can_route_command "${executable##*/}" || return 0
        executable=$(type -P -- "$executable") || return 0
    fi
    mode=$(< "$record/mode")
    while IFS= read -r dir; do
        [[ $dir != "$desktop_root/commands" ]] || continue
        for file in "$dir/"*.desktop; do
            [[ -f $file ]] || continue
            alias=${file##*/}
            [[ $alias != "$id" ]] && desktop_id "$alias" && [[ ! -v seen[$alias] ]] || continue
            target=$desktop_data/applications/$alias
            entry=$record/shortcuts/$alias
            legacy=$desktop_root/$alias
            [[ ! -e $entry/generated ]] || continue
            if [[ -f $legacy/mode ]]; then
                # Older versions could save a distinct native rule for a Flatpak shortcut.
                [[ $kind == flatpak &&
                    $(< "$legacy/kind") == native && $(< "$legacy/mode") == "$mode" &&
                    ! -e $legacy/command-shim ]] || continue
                if [[ $file == "$target" ]]; then
                    cmp -s "$file" "$legacy/generated" || continue
                    [[ -f $legacy/original ]] || continue
                    file=$legacy/original
                fi
            fi
            seen[$alias]=1
            mapfile -d '' -t fields < <(desktop_launch_fields "$file")
            [[ ${#fields[@]} == 3 && ${fields[1]} != true && ${fields[2]} != true ]] || continue
            line=${fields[0]}
            if [[ $kind == flatpak ]]; then
                other=$(flatpak_desktop_app "$line") || continue
                [[ $other == "$executable" ]] || continue
            else
                other=$(desktop_executable "$line") || continue
                other=$(type -P -- "$other") || continue
                [[ $other -ef $executable ]] || continue
            fi
            mkdir -p "$entry" || return 1
            if [[ -f $legacy/original ]]; then
                cp -L -p -- "$legacy/original" "$entry/original" || return 1
            elif [[ ! -f $legacy/mode && -f $target ]]; then
                cp -L -p -- "$target" "$entry/original" || return 1
            fi
            if ! render_desktop "$file" "$id" "$kind" true > "$entry/generated" ||
                ! replace_launcher "$entry/generated" "$target"; then
                rm -rf -- "$entry"
                return 1
            fi
            if [[ -f $legacy/mode ]]; then rm -rf -- "$legacy" || return 1; fi
        done
    done < <(desktop_roots)
}

sync_saved_launchers() (
    [[ -d $desktop_root && ! -f $desktop_root/.shortcut-format-2 ]] || return 0
    local lock record id kind dir source target updated
    exec {lock}>"$desktop_root/.lock"
    flock "$lock" || return 1
    [[ ! -f $desktop_root/.shortcut-format-2 ]] || return 0
    for record in "$desktop_root/"*.desktop; do
        [[ -f $record/mode && -f $record/kind ]] || continue
        id=${record##*/}
        target=$desktop_data/applications/$id
        [[ -f $target ]] && cmp -s "$record/generated" "$target" || continue
        kind=$(< "$record/kind")
        source=$record/original
        if [[ ! -f $source ]]; then
            while IFS= read -r dir; do
                [[ $dir != "$desktop_data/applications" && -f $dir/$id ]] || continue
                source=$dir/$id
                break
            done < <(desktop_roots)
        fi
        [[ -f $source ]] || continue
        updated=$(mktemp "$record/.desktop.XXXXXXXX") || return 1
        if ! render_desktop "$source" "$id" "$kind" > "$updated" ||
            ! replace_launcher "$updated" "$target" ||
            ! mv -f -- "$updated" "$record/generated"; then
            rm -f -- "$updated"
            return 1
        fi
        sync_shortcuts "$id" "$source" "$kind" || return 1
    done
    touch "$desktop_root/.shortcut-format-2" || return 1
    refresh_desktop_launchers
)

restore_desktop_files() (
    local id=$1 record target kind old entry shortcut
    desktop_id "$id" || return 1
    record=$desktop_root/$id
    target=$desktop_data/applications/$id
    [[ -f $record/kind ]] || return 0
    if [[ -e $desktop_root/commands/$id ]]; then target=$record/launcher; fi
    kind=$(< "$record/kind")
    # Preserve any launcher edits made since enabling app routing.
    if [[ -f $target ]] && ! cmp -s "$target" "$record/generated"; then
        notify 'This desktop file was edited. Restore or move it before removing VPN routing.'
        return 1
    fi
    for entry in "$record/shortcuts/"*; do
        [[ -f $entry/generated ]] || continue
        shortcut=$desktop_data/applications/${entry##*/}
        if [[ -f $shortcut ]] && ! cmp -s "$shortcut" "$entry/generated"; then
            notify 'A related shortcut was edited. Restore or move it before removing VPN routing.'
            return 1
        fi
    done
    for entry in "$record/shortcuts/"*; do
        [[ -f $entry/generated ]] || continue
        shortcut=$desktop_data/applications/${entry##*/}
        if [[ -f $entry/original ]]; then
            replace_launcher "$entry/original" "$shortcut" || return 1
        else
            rm -f -- "$shortcut" || return 1
        fi
        rm -rf -- "$entry" || return 1
    done
    if [[ $kind == flatpak && -f $record/network ]]; then
        old=$(< "$record/network")
        if [[ $(flatpak_network "${id%.desktop}") == '!network' ]]; then
            restore_network "${id%.desktop}" "$old" || return 1
        fi
    fi
    if [[ -f $record/original ]]; then
        cp -p -- "$record/original" "$target" || return 1
    else
        rm -f -- "$target" || return 1
    fi
    if [[ -s $record/command-shim ]]; then
        rm -f -- "$command_dir/$(< "$record/command-shim")" || return 1
    fi
    rm -rf -- "$record" || return 1
    refresh_desktop_launchers
)

restore_desktop() (
    local id=$1 record source kind app_lock desktop_lock
    desktop_id "$id" || return 1
    record=$desktop_root/$id
    [[ -f $record/kind ]] || return 0
    exec {desktop_lock}>"$desktop_root/.lock"
    flock "$desktop_lock" || return 1
    [[ -f $record/kind ]] || return 0
    kind=$(< "$record/kind")
    source=$(desktop_file "$id") || source=$record/generated
    open_app_lock "$id" || return 1
    if ! flock -n "$app_lock" || ! app_closed "$id" "$kind" "$source"; then
        notify "Quit ${id%.desktop} completely before restoring its routing."
        return 1
    fi
    restore_desktop_files "$id"
)

reopen_routed_app() {
    local selected=$1 id=$2 mode=$3 launcher
    if [[ $mode != default && -f $desktop_root/$id/launcher ]]; then
        launcher=$desktop_root/$id/launcher
    else
        launcher=$(desktop_file "$selected") || launcher=$(desktop_file "$id") || launcher=
    fi
    # The desktop launcher calls back into the VPN helper and needs the app lock.
    exec {app_lock}>&- {desktop_lock}>&-
    if [[ -z $launcher ]] || ! gio launch "$launcher"; then
        notify 'VPN routing changed, but the app could not be reopened.'
    fi
    return 0
}

save_app_region() (
    local record=$1 region=$2 next
    next=$(mktemp "$record/.region.XXXXXXXX") || return 1
    trap 'rm -f -- "$next"' EXIT
    printf '%s\n' "$region" > "$next" && mv -fT -- "$next" "$record/region"
)

install_desktop() (
    local id=$1 mode=$2 source kind=native target record command name owner app_lock desktop_lock shim=
    local selected=$id reopen=false region=${3:-host} previous_region=host
    desktop_id "$id" && [[ $mode == vpn || $mode == direct || $mode == default ]] &&
        [[ $region =~ ^[a-zA-Z0-9_-]{1,64}$ ]] || return 1
    mkdir -p -- "$desktop_root" "$desktop_data/applications" || return 1
    exec {desktop_lock}>"$desktop_root/.lock"
    flock "$desktop_lock" || return 1
    source=$(desktop_file "$id") || source=
    if [[ -n $source ]]; then
        owner=$(shortcut_owner "$id" "$source") || return 1
        id=$owner
    fi
    record=$desktop_root/$id
    if [[ $mode == default && ! -f $record/mode ]]; then return 0; fi
    if [[ -f $record/region ]]; then previous_region=$(< "$record/region"); fi
    if [[ -f $record/mode && $(< "$record/mode") == "$mode" &&
        ( $mode != vpn || $region == "$previous_region" ) ]]; then return 0; fi
    target=$desktop_data/applications/$id
    source=$(desktop_file "$id") || { [[ -f $record/generated ]] && source=$record/generated; } || return 1
    name=$(desktop_value "$source" Name)
    if [[ -f $record/kind ]]; then
        kind=$(< "$record/kind")
    elif [[ $(flatpak_desktop_app "$(desktop_value "$source" Exec)") == "${id%.desktop}" ]] &&
        flatpak info "${id%.desktop}" >/dev/null 2>&1; then
        kind=flatpak
    fi
    open_app_lock "$id" || return 1
    close_app_before_change "$id" "$kind" "$source" "${name:-${id%.desktop}}" reopen || return $?
    if [[ -f $record/mode ]]; then
        if [[ $mode == default ]]; then
            restore_desktop_files "$id" || return 1
            if [[ $reopen == true ]]; then reopen_routed_app "$selected" "$id" "$mode"; fi
            return 0
        fi
        if [[ $mode == vpn && $(< "$record/mode") == vpn ]]; then
            save_app_region "$record" "$region" || return 1
            if [[ $reopen == true ]]; then reopen_routed_app "$selected" "$id" "$mode"; fi
            return 0
        fi
        if [[ -e $desktop_root/commands/$id ]]; then source=$record/launcher; fi
        if ! cmp -s "$source" "$record/generated"; then
            notify 'The managed launcher changed. Restore it before switching routing.'
            return 1
        fi
        if [[ $kind == flatpak ]]; then
            flatpak override --user --unshare=network "${id%.desktop}" || return 1
        fi
        if [[ $mode == vpn ]]; then save_app_region "$record" "$region" || return 1; fi
        local next_mode
        next_mode=$(mktemp "$record/.mode.XXXXXXXX") || return 1
        if printf '%s\n' "$mode" > "$next_mode" && mv -f -- "$next_mode" "$record/mode"; then
            refresh_desktop_launchers
            if [[ $reopen == true ]]; then reopen_routed_app "$selected" "$id" "$mode"; fi
            return 0
        fi
        rm -f -- "$next_mode"
        return 1
    fi
    source=$(desktop_file "$id") || return 1
    if [[ $source == "$desktop_root/commands/$id" ]]; then target=$record/launcher; fi
    [[ $(desktop_value "$source" Hidden) != true && $(desktop_value "$source" Terminal) != true ]] || return 1
    command=$(desktop_value "$source" Exec)
    [[ -n $command ]] || return 1
    if [[ $kind == flatpak ]]; then
        flatpak_executable "${id%.desktop}" >/dev/null || return 1
    else
        shim=$(desktop_executable "$command") || shim=
        shim=${shim##*/}
        can_route_command "$shim" || shim=
        if [[ -n $shim && -e $command_dir/$shim ]]; then
            notify "Another saved routing policy already owns the $shim command."
            return 1
        fi
    fi
    mkdir -- "$record" || return 1
    trap 'if [[ -n $shim ]]; then rm -f -- "$command_dir/$shim"; fi; rm -rf -- "$record"' EXIT
    printf '%s\n' "$kind" > "$record/kind"
    printf '%s\n' "$mode" > "$record/mode"
    if [[ $mode == vpn ]]; then save_app_region "$record" "$region" || return 1; fi
    if [[ -e $target ]]; then cp -L -p -- "$target" "$record/original" || return 1; fi
    if [[ $kind == flatpak ]]; then
        flatpak_network "${id%.desktop}" > "$record/network"
    elif [[ -n $shim ]]; then
        mkdir -p "$command_dir" || return 1
        printf '%s\n' "$shim" > "$record/command-shim" || return 1
        printf '#!/usr/bin/env bash\nexec walker-vpn desktop %q -- %q "$@"\n' \
            "$id" "$shim" > "$command_dir/$shim" && chmod 700 "$command_dir/$shim" || return 1
    fi
    render_desktop "$source" "$id" "$kind" > "$record/generated" || return 1
    temporary=$(mktemp "$desktop_data/applications/.walker.XXXXXXXX") || return 1
    if [[ $kind == flatpak ]] && ! flatpak override --user --unshare=network "${id%.desktop}"; then
        rm -f -- "$temporary"
        return 1
    fi
    if ! cp -- "$record/generated" "$temporary" || ! mv -f -- "$temporary" "$target"; then
        rm -f -- "$temporary"
        if [[ $kind == flatpak ]]; then restore_network "${id%.desktop}" "$(< "$record/network")"; fi
        return 1
    fi
    trap - EXIT
    if [[ $target == "$desktop_data/applications/"* ]]; then
        if [[ -f $record/original ]]; then source=$record/original; fi
        sync_shortcuts "$id" "$source" "$kind" || return 1
        refresh_desktop_launchers
    fi
    if [[ $reopen == true ]]; then reopen_routed_app "$selected" "$id" "$mode"; fi
)

launch_desktop_protected() (
    local launch_error_file failure attempt
    launch_error_file=$(mktemp) || return 1
    trap 'rm -f -- "$launch_error_file"' EXIT
    for attempt in 1 2 3 4; do
        : > "$launch_error_file"
        if run_protected "$@" </dev/null; then return 0; fi
        failure=$(< "$launch_error_file")
        [[ $failure == RETRY && $attempt != 4 ]] || break
        sleep "$attempt"
    done
    case $failure in
        'ERROR '*) notify "${failure#ERROR }" ;;
        RETRY) notify 'The app is still shutting down. Try opening it again when it has closed.' ;;
        *) notify 'Could not launch the application with its network policy.' ;;
    esac
    return 1
)

desktop_launch() (
    local id=${1:-} record kind mode source app_lock executable managed_command flatpak_command_override= app_region=host
    desktop_id "$id" || return 2
    shift
    if [[ ${1:-} == --flatpak-command && ${2:-} =~ ^[a-zA-Z0-9_./][a-zA-Z0-9_./+-]*$ ]]; then
        flatpak_command_override=$2
        shift 2
    fi
    [[ ${1:-} == -- ]] || return 2
    shift
    record=$desktop_root/$id
    if [[ -f $record/kind && $(< "$record/kind") == flatpak ]] && ! repair_flatpak_export "$id"; then
        notify 'Could not refresh the Flatpak launcher while keeping its saved route.'
        return 1
    fi
    open_app_lock "$id" || return 1
    local first_launch=false
    if flock -xn "$app_lock"; then
        first_launch=true
    elif ! flock -sn "$app_lock"; then
        notify 'This app’s network route is being updated. Try again.'
        return 1
    fi
    record=$desktop_root/$id
    if [[ ! -f $record/mode || ! -f $record/kind ]]; then
        notify 'Enable the VPN-only policy for this app in App routing before launching it.'
        return 1
    fi
    kind=$(< "$record/kind")
    mode=$(< "$record/mode")
    if [[ -n ${required_mode:-} && $mode != "$required_mode" ]]; then
        notify 'This launch requires the app’s VPN-only policy.'
        return 1
    fi
    source=$(desktop_file "$id") || source=$record/generated
    if [[ $first_launch == true ]] && ! app_closed "$id" "$kind" "$source"; then
        notify 'Quit the existing app completely before launching it with VPN routing.'
        return 1
    fi
    if [[ $first_launch == true ]]; then
        flock -s "$app_lock" || return 1
        # A policy update may have acquired the lock during its conversion.
        [[ -f $record/mode && $(< "$record/mode") == "$mode" &&
            -f $record/kind && $(< "$record/kind") == "$kind" ]] || return 1
    fi
    if [[ $mode == vpn && -f $record/region ]]; then app_region=$(< "$record/region"); fi
    if [[ $kind == flatpak ]]; then
        if ! executable=${flatpak_command_override:-$(flatpak_executable "${id%.desktop}")}; then
            notify 'Could not read the installed Flatpak’s launch command.'
            return 1
        fi
        prepare_flatpak_session ||
            { notify 'Flatpak could not initialize its DNS monitor.'; return 1; }
        launch_desktop_protected "$mode" flatpak "${id%.desktop}" "$executable" "$@"
    else
        launch_desktop_protected "$mode" native "${id%.desktop}" "$@"
    fi
)

restore_all() {
    local entry result=0
    for entry in "$desktop_root/"*.desktop; do
        [[ -d $entry ]] || continue
        restore_desktop "${entry##*/}" || result=1
    done
    return "$result"
}
