#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/lib/session-env.sh"
source "$root/lib/app-service.sh"
account=example
getent() { printf 'example:x:1000:100:Example:/home/example:/bin/sh\n'; }
fail() { return 1; }
acquire() {
    # Verify decoded fields at the point just before privileged work.
    printf '%s\0' "$mode" "$app_kind" "$app_id" "$forward_files" "${args[@]}" "${session[@]}"
    return 1
}
request=$(jq -nc '{
    mode: "direct", kind: "flatpak", app_id: "org.example.App",
    job: "00000000-0000-0000-0000-000000000000", forward_files: false,
    argv: ["program", "--flag", "", "two words", "first\nsecond\n"],
    session: {QT_QPA_PLATFORMTHEME:"kde", TZ:"Etc/GMT+5", GTK_PATH:"one\ntwo\n",
              DBUS_SESSION_BUS_ADDRESS:"unfiltered", QT_PLUGIN_PATH:"bad\u0000value"}
}')
mapfile -d '' -t observed < <(launch_app || :)
expected=(direct flatpak org.example.App false program --flag '' 'two words' $'first\nsecond\n'
          QT_QPA_PLATFORMTHEME=kde $'GTK_PATH=one\ntwo\n')
[[ ${#observed[@]} == ${#expected[@]} ]]
for i in "${!expected[@]}"; do [[ ${observed[i]} == "${expected[i]}" ]]; done

for invalid in '.mode = "bogus"' '.argv = []' '.argv[0] = 42' '.argv[0] = "app\u0000"' '.app_id = "org.example.*"'; do
    malformed=$(jq -c "$invalid" <<< "$request")
    mapfile -d '' -t observed < <(request=$malformed launch_app || :)
    [[ ${#observed[@]} == 0 ]]
done
printf 'Launch validation and argument preservation passed.\n'
