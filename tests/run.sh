#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)
while IFS= read -r file; do bash -n "$file"; done < <(find "$root/bin" "$root/lib" "$root/system" -type f ! -name '*.crt' ! -name '*.service' ! -name '*.socket' ! -name '*.timer')
bash -n "$root/install.sh"
bash -n "$root/cleanup-user.sh"
bash -n "$root/migrate-legacy.sh"
for test in "$root/tests/"*.sh; do
    case ${test##*/} in run.sh|transport-kernel.sh) continue ;; esac
    printf 'Checking %s\n' "${test##*/}"
    bash "$test"
done
if find "$root" -path "$root/.git" -prune -o -name '*.py' -print | rg -q .; then
    echo 'Python code is not permitted in this backend.' >&2
    exit 1
fi
