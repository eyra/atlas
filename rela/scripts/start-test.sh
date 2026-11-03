#!/usr/bin/env bash
# Start the Atlas test rela on this Mac: loopback only, its own dataset.
#
#   start-test.sh            # runs in the foreground; Ctrl-C stops it
#
# The description (schema.yaml, plus the data-entry.yaml rela-server needs)
# next to scripts/ is copied into the data
# directory on every start, so changing the description is: edit, restart.
# Data stays in $ATLAS_RELA_DATA and is never shared with another store.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
root="${ATLAS_TEST_ROOT:-$HOME/.local/share/atlas/test}"
data="${ATLAS_RELA_DATA:-$root/rela}"
bin="${ATLAS_RELA_BIN:-$root/bin}"
port="${ATLAS_RELA_PORT:-7690}"

version=26.10.14
archive="rela_${version}_darwin_arm64.tar.gz"
sha256=8360fa3dfc396b71a9c1b1d0d97cadbef7b5308798c55248eb052946fdfc357e

# The live agent store listens on 7612; never start on it.
if [ "$port" = 7612 ]; then echo "start-test: port 7612 is the live store" >&2; exit 1; fi

if [ ! -x "$bin/rela-server" ] || [ "$("$bin/rela" version)" != "rela version $version" ]; then
  echo "start-test: installing rela $version into $bin"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/$archive" \
    "https://github.com/sourcehaven-bv/rela/releases/download/v$version/$archive"
  echo "$sha256  $tmp/$archive" | shasum -a 256 -c -
  mkdir -p "$bin"
  tar -xzf "$tmp/$archive" -C "$bin" rela rela-server
  rm -rf "$tmp"
fi

mkdir -p "$data/entities" "$data/relations"
cp "$here/schema.yaml" "$here/data-entry.yaml" "$data/"
"$bin/rela" --project "$data" --quiet validate

# No acl.yaml and a loopback bind: every local caller may read and write.
# RELA_DATAENTRY_USER names the writer in rela's audit log.
export RELA_DATAENTRY_USER="${RELA_DATAENTRY_USER:-atlas-test}"
exec "$bin/rela-server" -project "$data" -bind 127.0.0.1 -port "$port" -quiet
