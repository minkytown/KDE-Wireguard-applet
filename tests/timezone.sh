#!/usr/bin/env bash
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/../lib/session-env.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/config" "$scratch/database/Etc"
printf 'test zone file\n' > "$scratch/database/Etc/UTC"
ln -s "$scratch/database" "$scratch/config/zoneinfo"
localtime=$scratch/config/localtime
timezone_file=$scratch/config/timezone
for target in zoneinfo/Etc/UTC "$scratch/config/zoneinfo/Etc/UTC" ../config/./zoneinfo/Etc/UTC; do
    ln -sf "$target" "$localtime"
    TZ= read_desktop_timezone "$localtime" "$timezone_file"
    [[ $desktop_tzdir == "$scratch/config/zoneinfo" && $desktop_tz == Etc/UTC ]]
done
ln -sf "$scratch/database/Etc/UTC" "$localtime"
TZDIR="$scratch/database" read_desktop_timezone "$localtime" "$timezone_file"
[[ $desktop_tzdir == "$scratch/database" && $desktop_tz == Etc/UTC ]]

rm "$localtime"
cp "$scratch/database/Etc/UTC" "$localtime"
printf 'Etc/UTC\n' > "$timezone_file"
TZDIR="$scratch/database" read_desktop_timezone "$localtime" "$timezone_file"
[[ $desktop_tzdir == "$scratch/database" && $desktop_tz == Etc/UTC ]]
printf 'different zone file\n' > "$localtime"
TZDIR="$scratch/database" read_desktop_timezone "$localtime" "$timezone_file"
[[ $desktop_tzdir == "$scratch/database" && -z $desktop_tz ]]
printf 'Timezone detection handles symlinks, copied files and stale timezone names.\n'
