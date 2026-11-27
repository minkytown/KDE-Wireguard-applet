#!/usr/bin/env bash
set -euo pipefail
lib=$(cd -- "${BASH_SOURCE[0]%/*}/../lib" && pwd)
source "$lib/session-env.sh"
source "$lib/app-service.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
run=$scratch
account=example
app_netns_dir=$scratch/netns
work=$scratch/existing
namespace=wv0123456789
mkdir "$app_netns_dir" "$work"
touch "$app_netns_dir/$namespace" "$work/lease"
printf '%s %s %s %s\n' "$namespace" private0 vpn "$work" > "$run/active-native-org.example.Client"
getent() { printf 'example:x:1000:100:Example:/home/example:/bin/sh\n'; }
acquire() { :; }
guard_init() { :; }
ensure_host_for_app() { :; }
release() { :; }
fail() { return 1; }
test_namespace_ip() {
    [[ $1 == netns && $2 == exec && $3 == wv0123456789 ]]
    [[ ${*: -2:1} == example-client && ${*: -1} == "$magnet" ]]
    # The caller must keep a shared lease while the command runs.
    if flock -xn "$scratch/existing/lease" true; then return 1; fi
    printf '%s\n' "${@: -1}" > "$scratch/delivered"
}
export -f test_namespace_ip
# The namespace launcher execs ip, so provide a test binary on PATH.
mkdir "$scratch/bin"
printf '#!/usr/bin/env bash\ntest_namespace_ip "$@"\n' > "$scratch/bin/ip"
chmod +x "$scratch/bin/ip"
export PATH="$scratch/bin:$PATH" magnet='magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Example%20file' scratch
request=$(jq -nc --arg magnet "$magnet" '{
    mode:"vpn",kind:"native",app_id:"org.example.Client",
    job:"00000000-0000-0000-0000-000000000001",argv:["example-client",$magnet]
}')
(launch_app)
[[ $(< "$scratch/delivered") == "$magnet" ]]
[[ $(< "$run/result-00000000-0000-0000-0000-000000000001") == 0 ]]
rm "$scratch/delivered"
if (request=$(jq '.mode="direct"' <<< "$request"); launch_app); then exit 1; fi
[[ ! -e $scratch/delivered ]]
if (request=$(jq '.region="example-region"' <<< "$request"); launch_app); then exit 1; fi
[[ ! -e $scratch/delivered ]]
printf '%s %s %s %s %s\n' "$namespace" private0 vpn "$work" example-region > "$run/active-native-org.example.Client"
if (launch_app); then exit 1; fi
[[ ! -e $scratch/delivered ]]
(request=$(jq '.region="example-region"' <<< "$request"); launch_app)
[[ $(< "$scratch/delivered") == "$magnet" ]]
printf 'A second launch preserved the magnet URI. Mismatched app modes and locations were rejected.\n'

# The initiating command has exited, but a detached app process is still live.
rm -f "$app_netns_dir/$namespace"
ln -s /proc/self/ns/net "$app_netns_dir/$namespace"
sleep .5 &
detached=$!
trap 'kill "$detached" 2>/dev/null || :; rm -rf "$scratch"' EXIT
ip() { echo scan >> "$scratch/scans"; printf '%s\n' "$detached"; }
wait_for_app_processes "$namespace" "$UID"
wait "$detached"
[[ $(wc -l < "$scratch/scans") == 2 ]]
printf 'Detached apps keep the protected namespace alive until the last process exits.\n'
