#!/usr/bin/env bash
# Restore the previous Python client's launchers without loading its code.
set -euo pipefail
umask 077
legacy_home=${PIA_LEGACY_HOME:-$HOME}
registry=$legacy_home/.config/pia-wireguard/apps.json
migration=${XDG_STATE_HOME:-$HOME/.local/state}/walker-vpn/legacy-migration.json
desktop_data=${XDG_DATA_HOME:-$HOME/.local/share}
root_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
check_registry() {
    jq -e 'type == "object" and all(to_entries[];
        (.key | test("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,199}$")) and
        (.value.kind == "Flatpak") and
        ((.value.mode // "vpn") | IN("vpn","direct")) and
        (.value.previous_network | . == null or . == "network" or . == "!network") and
        (.value.previous_launcher | . == null or
            (type == "object" and ((.link | type == "string") or
             ((.data | type == "string") and (.mode | type == "number"))))))' "$registry" >/dev/null
}
case ${1:-} in
    --check) [[ ! -f $registry ]] || check_registry ;;
    --restore)
        [[ -f $registry ]] || exit 0
        check_registry
        mkdir -p "${migration%/*}"
        [[ -f $migration ]] || cp -p -- "$registry" "$migration"
        source "$root_dir/lib/desktop.sh"
        while IFS= read -r id; do
            target=$desktop_data/applications/$id.desktop
            if [[ -f $target && ! -L $target ]] && grep -q '^X-PIA-Protected-Launcher=true$' "$target"; then
                if jq -e --arg id "$id" '.[$id].previous_launcher == null' "$registry" >/dev/null; then
                    rm -- "$target"
                else
                    temporary=$(mktemp "${target}.migration.XXXXXXXX")
                    if jq -e --arg id "$id" '.[$id].previous_launcher.link | type == "string"' "$registry" >/dev/null; then
                        link=$(jq -r --arg id "$id" '.[$id].previous_launcher.link' "$registry")
                        rm -- "$temporary"
                        ln -s -- "$link" "$temporary"
                    else
                        jq -r --arg id "$id" '.[$id].previous_launcher.data' "$registry" | base64 -d > "$temporary"
                        permissions=$(jq -r --arg id "$id" '.[$id].previous_launcher.mode' "$registry")
                        printf -v permissions '%o' "$permissions"
                        chmod "$permissions" "$temporary"
                    fi
                    mv -fT -- "$temporary" "$target"
                fi
            fi
            old=$(jq -r --arg id "$id" '.[$id].previous_network // ""' "$registry")
            restore_network "$id" "$old"
        done < <(jq -r 'keys[]' "$registry")
        # The old registry is retained as a backup, separate from active settings.
        mv -- "$registry" "${registry}.pre-bash-backend"
        ;;
    --apply)
        [[ -s $migration ]] || exit 0
        while IFS=$'\t' read -r id mode; do
            printf 'Migrating VPN route: %s\n' "$id"
            result=$(walker-vpn app-set-json "$id.desktop" on --mode "$mode")
            jq -e 'has("error") | not' <<< "$result" >/dev/null || {
                echo "Could not migrate routing for $id. Saved policies: $migration" >&2
                exit 1
            }
        done < <(jq -r 'to_entries[] | [.key,(.value.mode // "vpn")] | @tsv' "$migration")
        mv -- "$migration" "${migration%.json}.completed.json"
        ;;
    *) exit 2 ;;
esac
