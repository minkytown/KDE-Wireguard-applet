# Plasma adapter. No credentials are passed in argv or written by the client.
panel_apps() {
    local dir file id name icon owner mode region
    local -A seen=()
    local -a files=()
    while IFS= read -r dir; do
        for file in "$dir/"*.desktop; do
            [[ -f $file ]] || continue
            id=${file##*/}
            desktop_id "$id" && [[ ! -v seen[$id] ]] || continue
            seen[$id]=1
            files+=("$file")
        done
    done < <(desktop_roots)
    (( ${#files[@]} )) || return 0
    while IFS= read -r -d '' id && IFS= read -r -d '' name &&
          IFS= read -r -d '' icon && IFS= read -r -d '' owner; do
        if ! desktop_id "$owner" || [[ ! -f $desktop_root/$owner/shortcuts/$id/generated ]]; then owner=$id; fi
        mode=default region=host
        [[ ! -f $desktop_root/$owner/mode ]] || mode=$(< "$desktop_root/$owner/mode")
        [[ ! -f $desktop_root/$owner/region ]] || region=$(< "$desktop_root/$owner/region")
        printf '%s\0' "$id" "$name" "$icon" "$mode" "$region"
    done < <(gawk '
        BEGINFILE { delete values; entry=0 }
        /^\[/ { entry=($0=="[Desktop Entry]") }
        entry && /^(Name|Icon|Exec|Hidden|NoDisplay|Terminal)=/ {
            key=substr($0,1,index($0,"=")-1)
            if (!(key in values)) values[key]=substr($0,length(key)+2)
        }
        ENDFILE {
            if (values["Hidden"]!="true" && values["NoDisplay"]!="true" &&
                values["Terminal"]!="true" && length(values["Name"]) && length(values["Exec"])) {
                id=FILENAME; sub(/^.*\//,"",id)
                split(values["Exec"],argv,/[[:space:]]+/)
                owner=(argv[1]=="walker-vpn" && argv[2]=="desktop" ? argv[3] : id)
                printf "%s%c%s%c%s%c%s%c",id,0,values["Name"],0,values["Icon"],0,owner,0
            }
        }
    ' "${files[@]}") | jq -Rc -s '
        split("\u0000") as $fields |
        range(0; ($fields|length)-1; 5) as $n |
        {id:$fields[$n],name:$fields[$n+1],icon:$fields[$n+2],
         required:($fields[$n+3]=="vpn"),excluded:($fields[$n+3]=="direct"),region:$fields[$n+4]}'
}

panel_credentials() {
    local username password result
    username=$(kdialog --title 'PIA Credentials' --inputbox 'PIA VPN username (p…)') || return 1
    [[ $username =~ ^p[0-9]{1,20}$ ]] || { kdialog --error 'Enter your PIA VPN username beginning with p.'; return 1; }
    password=$(kdialog --title 'PIA Credentials' --password 'PIA VPN password') || return 1
    [[ -n $password ]] || return 1
    result=$(printf '%s\n%s\n' "$username" "$password" |
        jq -ncR 'input as $username | input as $password | {action:"login",provider:"pia",$username,$password}' |
        call 2>&1) || { unset password; kdialog --error "$result"; return 1; }
    unset password
    notify 'PIA login verified and encrypted on this computer.'
}

panel_command() {
    local action=$1 result id setting mode region
    shift
    case $action in
        panel-status)
            read_status | jq -ec '{
                connection: (({connected:"Connected",connecting:"Connecting",reconnecting:"Reconnecting"}[.connection] // "Disconnected")
                    + (if .region != "" then " · " + .region else "" end)),
                killSwitch: ({on:"On",off:"Off",degraded:"Degraded"}[.kill] // "Unavailable"),
                bootReconnect: .bootReconnect}'
            ;;
        locations-json)
            request locations | jq -ec '[{id:"optimal",name:"Optimal",country:"Fastest reachable",code:""}] + .'
            ;;
        credentials) panel_credentials ;;
        system-connect)
            [[ $# == 2 && $1 == --region && $2 =~ ^[a-zA-Z0-9_-]{1,64}$ ]] || return 2
            result=$(request connect "$2" 2>&1) || { kdialog --error "$result"; return 1; }
            ;;
        system-disconnect)
            result=$(request disconnect 2>&1) || { kdialog --error "$result"; return 1; }
            ;;
        kill-switch-set|boot-reconnect-set)
            [[ $# == 1 && ( $1 == on || $1 == off ) ]] || return 2
            if [[ $action == kill-switch-set ]]; then request "kill-$1"; else request "boot-$1"; fi
            ;;
        app-list-json) panel_apps | jq -sc '{apps:sort_by(.name|ascii_downcase)}' ;;
        app-set-json)
            [[ $# -ge 4 ]] || return 2
            id=$1 setting=$2
            shift 2
            [[ $1 == --mode && ( $2 == vpn || $2 == direct ) ]] || return 2
            mode=$2 region=${3:-host}
            desktop_id "$id" && [[ $setting == on || $setting == off ]] &&
                [[ $region =~ ^[a-zA-Z0-9_-]{1,64}$ ]] || return 2
            [[ $setting != off ]] || mode=default
            # Never close a user's running application to change its policy.
            if ! result=$(install_desktop "$id" "$mode" "$region" 2>&1); then
                panel_apps | jq -sc --arg error 'Quit the app completely before changing its route. Check the journal if the problem persists.' \
                    '{apps:sort_by(.name|ascii_downcase),$error}'
                return
            fi
            panel_apps | jq -sc '{apps:sort_by(.name|ascii_downcase)}'
            ;;
        *) return 2 ;;
    esac
}
