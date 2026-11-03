#!/usr/bin/env bash
# atlas move-to-fly: copy an environment's data from this Mac to its apps on Fly
# (IS-Atlas-26). bin/atlas runs it for an environment whose settings have a "fly" section.
#
#   atlas move-to-fly --env test [--from <folder>] [--dry-run]
#
# <folder> holds rela/ (rela's data folder) and beam/ (State's own data), as
# ~/.local/share/atlas/test does; by default the folder in the settings' fly.move_from.
# Point --from at a backup of it to move from the backup.
#
#  1. Checks, and sends nothing when one fails: rela/ and beam/ are there; no rela serves
#     rela/ right now (a copy of a store in use can catch a half-written file); this build's
#     description describes all of its data (what `atlas restart` checks too); and counts
#     the items per kind.
#  2. Sends rela/ to the rela app and beam/ to the core app, as /data/incoming/<name>.tar.gz.
#  3. Restarts both machines, rela first. At boot fly/apply-move.sh moves what was there
#     to /data/before-move/<time>-<name> (kept) and puts the copy in its place.
#  4. Counts the items per kind on Fly and compares them with step 1.
#
# --dry-run does step 1, shows what Fly holds now, and sends nothing.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
app="${ATLAS_FLY_APP:?run through bin/atlas move-to-fly}"
rela_app="${ATLAS_FLY_RELA_APP:?run through bin/atlas move-to-fly}"
from="${ATLAS_MOVE_FROM:-}"
dry=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from) [ -n "${2:-}" ] || { echo "move-to-fly: --from needs a folder" >&2; exit 2; }; from="$2"; shift 2 ;;
    --from=?*) from="${1#--from=}"; shift ;;
    --dry-run) dry=1; shift ;;
    *) echo "move-to-fly: unknown option $1; see atlas help" >&2; exit 2 ;;
  esac
done
from="${from/#\~/$HOME}"
[ -n "$from" ] && [ -d "$from" ] || { echo "move-to-fly: no folder to move from ($from)" >&2; exit 1; }
from="$(cd "$from" && pwd -P)"
fly="$(command -v fly || command -v flyctl)" || { echo "move-to-fly: install flyctl first" >&2; exit 1; }
fail() { echo "move-to-fly: $*" >&2; exit 1; }

echo "From:  $from (this Mac)"
echo "To:    $rela_app (rela/) and $app (beam/), on Fly"
echo

# 1. Checks.
[ -d "$from/rela/entities" ] || fail "$from/rela has no rela data (no entities/)"
[ -d "$from/beam" ] || fail "$from/beam is missing: State's own data (who set each link, which facts were answered) moves too"

serving="$(pgrep -fl "rela-server -project $from/rela( |$)" 2>/dev/null || true)"
if [ -n "$serving" ]; then
  pid="${serving%% *}"
  if [ -z "$dry" ]; then
    fail "a rela still serves $from/rela (pid $pid); stop it first (kill $pid), or move from a backup with --from"
  fi
  echo "Note:  a rela still serves $from/rela (pid $pid); a real run refuses until it is stopped, or use --from <backup>"
fi

# The pinned rela, for the description check; installed beside the tunnel's files.
bin="${ATLAS_TEST_ROOT:?}/bin"
ATLAS_RELA_BIN="$bin" "$root/rela/scripts/start-test.sh" install >&2
if ! orphans="$(ATLAS_RELA_DATA="$from/rela" ATLAS_RELA_BIN="$bin" "$root/rela/scripts/description.sh" fits)"; then
  echo "move-to-fly: this build's description no longer describes data in $from/rela:" >&2
  echo "$orphans" | sed 's/^/  /' >&2
  fail "migrate that data first, on this Mac, then move it"
fi
echo "Check: this build's description describes all of it"

here="$("$root/fly/counts.sh" "$from/rela")"
remote_counts() { "$fly" ssh console -q -a "$rela_app" -C "/app/fly/counts.sh /data/rela" 2>/dev/null | tr -d '\r'; }
there="$(remote_counts || echo "(could not read: is $rela_app running? atlas status)")"
echo
echo "Here, to send:"
echo "$here" | sed 's/^/  /'
echo "On Fly now (a real run keeps it there in /data/before-move):"
echo "$there" | sed 's/^/  /'
echo

if [ -n "$dry" ]; then
  echo "Dry run: nothing sent. A real run sends this, restarts $rela_app and $app, and compares the counts."
  exit 0
fi

# 2. Send. A half-sent archive is never applied: it is renamed only once complete.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for name in rela beam; do
  COPYFILE_DISABLE=1 tar -czf "$tmp/$name.tar.gz" --exclude '*.log' --exclude '*.pid' -C "$from/$name" .
done
send() { # app name
  echo "Sending $2/ to $1 ($(du -h "$tmp/$2.tar.gz" | cut -f1 | tr -d ' '))"
  "$fly" ssh console -q -a "$1" -C "mkdir -p /data/incoming" >/dev/null
  "$fly" ssh sftp put -a "$1" "$tmp/$2.tar.gz" "/data/incoming/$2.tar.gz.part" >/dev/null
  "$fly" ssh console -q -a "$1" -C "mv /data/incoming/$2.tar.gz.part /data/incoming/$2.tar.gz" >/dev/null
}
send "$rela_app" rela
send "$app" beam

# 3. Restart, rela first, so the core starts on the moved data.
machine() { "$fly" status -a "$1" --json | jq -r '.Machines[0].id'; }
passing() { "$fly" status -a "$1" --json | jq -e '.Machines[0] | .state == "started" and all(.checks[]?; .status == "passing")' >/dev/null; }
for target in "$rela_app" "$app"; do
  echo "Restarting $target"
  "$fly" machine restart "$(machine "$target")" -a "$target" >/dev/null
  for _ in $(seq 1 60); do passing "$target" && break; sleep 2; done
  passing "$target" || fail "$target did not come back; see: fly logs -a $target"
done

# 4. Compare.
there="$(remote_counts)"
if [ "$here" != "$there" ]; then
  echo "move-to-fly: the counts on Fly differ from the ones sent:" >&2
  diff <(echo "$here") <(echo "$there") >&2 || true
  fail "the earlier data on Fly is in /data/before-move on both apps"
fi
echo "Moved: the counts per kind on Fly are the ones sent. The earlier data on Fly is in /data/before-move."
