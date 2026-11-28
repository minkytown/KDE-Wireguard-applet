#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)
scratch=$(mktemp -d)
listener=
trap 'if [[ -n $listener ]]; then kill "$listener" 2>/dev/null || :; fi; rm -rf "$scratch"' EXIT
source <(sed -n '/^read_status() {/,/^}/p' "$root/bin/walker-vpn")
socket=$scratch/control.sock view=$scratch/view
mkdir "$view"
socat "UNIX-LISTEN:$socket,fork" EXEC:cat &
listener=$!
for (( n=0;n<100;n++ )); do [[ ! -S $socket ]] || break; sleep .01; done
[[ -S $socket ]]
request() { printf '{"fresh":true}\n'; }
printf '{"cached":true}\n' > "$view/status.json"
read_status | jq -e .cached >/dev/null
touch -d "@$((EPOCHSECONDS-60))" "$view/status.json"
read_status | jq -e .fresh >/dev/null
touch -d "@$((EPOCHSECONDS+60))" "$view/status.json"
read_status | jq -e .fresh >/dev/null
printf 'Expired and future-dated status caches require a fresh control query.\n'
