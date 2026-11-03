#!/usr/bin/env bash
# At boot, before anything reads it: put data that `atlas move-to-fly` sent in place.
#
#   apply-move.sh <name>   when /data/incoming/<name>.tar.gz exists, /data/<name> moves to
#                          /data/before-move/<time>-<name> (kept, never removed here) and
#                          the archive is unpacked as the new /data/<name>
#
# It runs while nothing serves the folder, so the copy is never half read or half written.
set -euo pipefail

name="$1"
archive="/data/incoming/$name.tar.gz"
[ -f "$archive" ] || exit 0

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p /data/before-move
if [ -e "/data/$name" ]; then
  mv "/data/$name" "/data/before-move/$stamp-$name"
  echo "apply-move: kept the earlier /data/$name as /data/before-move/$stamp-$name"
fi
mkdir -p "/data/$name.new"
tar -xzf "$archive" -C "/data/$name.new"
mv "/data/$name.new" "/data/$name"
rm -f "$archive"
echo "apply-move: /data/$name is now the data that atlas move-to-fly sent"
