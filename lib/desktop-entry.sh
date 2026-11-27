# Read and rewrite desktop files while leaving executable arguments to the desktop launcher.
desktop_id() { [[ $1 =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,199}\.desktop$ ]]; }

desktop_roots() {
    local dir
    printf '%s\n' "$desktop_data/applications" \
        "$desktop_data/flatpak/exports/share/applications" /var/lib/flatpak/exports/share/applications \
        "$desktop_root/commands"
    local -a dirs
    IFS=: read -ra dirs <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    for dir in "${dirs[@]}"; do
        [[ -n $dir ]] && printf '%s/applications\n' "$dir"
    done
}

desktop_file() {
    local dir found
    while IFS= read -r dir; do
        found=$dir/$1
        if [[ -f $found ]]; then printf '%s\n' "$found"; return 0; fi
    done <<< "$(desktop_roots)"
    return 1
}

desktop_value() {
    awk -v key="$2" '
        /^\[/ { entry=($0 == "[Desktop Entry]") }
        entry && index($0, key "=") == 1 { print substr($0,length(key)+2); exit }
    ' "$1"
}

desktop_executable() {
    local rest=$1 token
    local pattern='^[[:space:]]*("([^"]+)"|([^[:space:]]+))[[:space:]]*(.*)$'
    while [[ $rest =~ $pattern ]]; do
        token=${BASH_REMATCH[2]:-${BASH_REMATCH[3]}}
        rest=${BASH_REMATCH[4]}
        case "${token##*/}" in
            env|gamemoderun|prime-run|steam-run|--|-i|--ignore-environment|*=*) ;;
            -u|-C|--unset|--chdir)
                [[ $rest =~ $pattern ]] || return 1
                rest=${BASH_REMATCH[4]}
                ;;
            *) printf '%s\n' "$token"; return ;;
        esac
    done
    return 1
}

flatpak_desktop_app() {
    local exec_line=$1 executable
    executable=$(desktop_executable "$exec_line") || return 1
    [[ ${executable##*/} == flatpak ]] || return 1
    awk '
        {
            for (i=1; i<=NF && $i!="run"; i++) {}
            for (i++; i<=NF; i++) {
                if ($i ~ /^--/) continue
                if ($i ~ /^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+){2,}$/) { print $i; found=1 }
                break
            }
        }
        END { if (!found) exit 1 }
    ' <<< "$exec_line"
}

render_desktop() {
    local source=$1 id=$2 kind=$3 sibling=${4:-false}
    awk -v id="$id" -v kind="$kind" -v sibling="$sibling" '
        /^\[/ { entry=($0 == "[Desktop Entry]"); action=($0 ~ /^\[Desktop Action /) }
        entry && /^DBusActivatable=/ { next }
        (entry || action) && /^Exec=/ {
            line=substr($0,6)
            prefix="Exec=walker-vpn desktop " id
            if (kind=="flatpak") {
                # Flatpak exports supply an explicit command followed by the app ID.
                app=id
                sub(/\.desktop$/, "", app)
                found=0
                command=""
                while (match(line, /^[^[:space:]]+[[:space:]]*/)) {
                    token=substr(line,1,RLENGTH)
                    line=substr(line,RLENGTH+1)
                    sub(/[[:space:]]+$/, "", token)
                    if (token==app) { found=1; break }
                    if (token ~ /^--command=[A-Za-z0-9_./][A-Za-z0-9_./+-]*$/) command=substr(token,11)
                }
                if (!found) { if (entry) exit 1; next }
                gsub(/(^|[[:space:]])@@[uU]?([[:space:]]|$)/, " ", line)
                if ((action || sibling=="true") && command!="") prefix=prefix " --flatpak-command " command
            }
            print prefix " -- " line
            next
        }
        entry && /^\[Desktop Entry\]$/ {
            print; print "DBusActivatable=false"; print "X-Walker-VPN-Managed=true"; next
        }
        { print }
    ' "$source"
}

desktop_launch_fields() {
    awk '
        /^\[/ { if (entry) exit; entry=($0 == "[Desktop Entry]") }
        entry && /^(Exec|Hidden|Terminal)=/ {
            key=substr($0,1,index($0,"=")-1)
            if (!(key in values)) values[key]=substr($0,length(key)+2)
        }
        END { printf "%s%c%s%c%s%c", values["Exec"], 0, values["Hidden"], 0, values["Terminal"], 0 }
    ' "$1"
}
