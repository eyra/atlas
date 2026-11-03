#!/usr/bin/env bash
# What a rela data folder holds: the number of items per kind (a folder under entities/,
# named by its plural) and of links. move-to-fly compares the two sides with it; the rela
# image has it too, so Fly's side is counted the same way.
#
#   counts.sh <rela data folder>    one "<plural> <count>" per line, then "links <count>"
set -euo pipefail

cd "$1"
for folder in entities/*/; do
  [ -d "$folder" ] || continue
  echo "$(basename "$folder") $(find "$folder" -type f | wc -l | tr -d ' ')"
done
echo "links $(find relations -type f 2>/dev/null | wc -l | tr -d ' ')"
