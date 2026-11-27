#!/usr/bin/env bash
set -euo pipefail
handler=${BASH_SOURCE[0]%/*}/../bin/open-link
scratch=$(mktemp -d)
listener=
trap 'if [[ -n $listener ]]; then kill "$listener" 2>/dev/null || :; fi; rm -rf "$scratch"' EXIT
export OPENER_LOG=$scratch/opened
cat >"$scratch/opener" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$OPENER_LOG"
SH
chmod +x "$scratch/opener"
url='https://example.invalid/path?a=b&c=d'
[[ $(printf '%s\n' "$url" | bash "$handler" serve "$scratch/opener") == ok ]]
printf 'open\0%s\0' "$url" | cmp - "$OPENER_LOG"
rm "$OPENER_LOG"
directory="$scratch/folder #1 %"
mkdir "$directory"
touch "$scratch/ordinary-file"
for invalid in file:///etc/passwd "$scratch/ordinary-file" "file://remote$directory" \
    "$scratch/nonexistent" '--help' 'https://example.invalid/unescaped space' ftp://example.invalid; do
    if printf '%s\n' "$invalid" | bash "$handler" serve "$scratch/opener"; then exit 1; fi
    [[ ! -e $OPENER_LOG ]]
done
printf -v long '%08200d' 0
if printf 'https://example.invalid/%s\n' "$long" | bash "$handler" serve "$scratch/opener"; then exit 1; fi
[[ ! -e $OPENER_LOG ]]
export XDG_RUNTIME_DIR=$scratch
socket=$scratch/walker-vpn-links.sock
socat "UNIX-LISTEN:$socket,fork" "EXEC:bash $handler serve $scratch/opener" &
listener=$!
for (( attempt=0; attempt<100; attempt++ )); do
    [[ -S $socket ]] && break
    sleep .02
done
[[ -S $socket ]]
for target in "$directory" "file://$scratch/folder%20%231%20%25" "file://localhost$scratch/folder%20%231%20%25"; do
    bash "$handler" client false socat "$target"
    printf 'open\0%s\0' "$directory" | cmp - "$OPENER_LOG"
    rm "$OPENER_LOG"
done
bash "$handler" client "$scratch/opener" false '/tmp/a local file'
printf '/tmp/a local file\0' | cmp - "$OPENER_LOG"
printf 'Web links and local directories reach the desktop. Ordinary files stay local and invalid requests are rejected.\n'
