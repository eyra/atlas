#!/usr/bin/env bash
# rela of an Atlas environment on Fly: its data on the volume (/data/rela), this image's
# description, listening on the environment's own private network only (the app has no
# public address). The same start-test.sh as on a Mac, with another bind and folders.
set -euo pipefail

/app/fly/apply-move.sh rela

export ATLAS_RELA_DATA=/data/rela ATLAS_RELA_BIN=/app/bin ATLAS_RELA_BIND=:: ATLAS_RELA_PORT=7690

# As bin/atlas does on a Mac (IS-Atlas-73): a description that no longer describes data
# rela holds does not start; that data needs a migration first.
if [ -d /data/rela/entities ] && ! orphans="$(/app/rela/scripts/description.sh fits)"; then
  echo "rela: this build's description no longer describes data rela holds:"
  echo "$orphans" | sed 's/^/  /'
  echo "rela: not starting; migrate that data first (docs/guides/test-on-fly.md)"
  exit 1
fi

exec /app/rela/scripts/start-test.sh
