#!/usr/bin/env bash
set -euo pipefail
lib=$(cd -- "${BASH_SOURCE[0]%/*}/../lib" && pwd)
# Load the service functions without reading a control socket.
source <(sed '/^case "\${1:-}" in/,$d' "$lib/service.sh") "$lib" example
set -e
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
run=$scratch/run state=$scratch/state
mkdir "$run" "$state"
pia_token() {
    [[ $1 == p1234 && $2 == 'fixture-only password' ]] || return 1
    touch "$scratch/provider-called"
    printf '%s\n' fixture-token
}
systemd-creds() {
    local output=${!#}
    cat >/dev/null
    printf '%s\n' encrypted-fixture > "$output"
    [[ ! -e $scratch/encrypt-fail ]]
}
printf '%s\n' original > "$state/pia-login.cred"
printf '%s\n' old-token > "$run/pia-token"
for password in $'fixture-only password\n' $'fixture-only password\r' fixture-with-NUL; do
    request=$(jq -nc --arg password "$password" '
        {username:"p1234", password: (if $password == "fixture-with-NUL"
            then "fixture-only pass\u0000word" else $password end)}')
    if save_login; then exit 1; fi
    [[ ! -e $scratch/provider-called && $(< "$state/pia-login.cred") == original ]]
done
request='{"username":"p1234","password":"fixture-only password"}'
touch "$scratch/encrypt-fail"
if save_login; then exit 1; fi
[[ $(< "$state/pia-login.cred") == original && $(< "$run/pia-token") == old-token ]]
[[ -z $(find "$state" -mindepth 1 ! -name pia-login.cred -print -quit) ]]
rm "$scratch/encrypt-fail"
save_login
[[ $(< "$state/pia-login.cred") == encrypted-fixture && $(< "$run/pia-token") == fixture-token ]]
printf 'Invalid credential framing is rejected and an interrupted credential write preserves the previous login.\n'
