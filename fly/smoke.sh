#!/usr/bin/env bash
# The smoke check against an environment deployed on Fly; CI runs it after every deploy of
# test. It reads only: it never writes the environment's data.
#
#   smoke.sh <env> [<image label>]
#
#  1. With a label: the core on Fly runs that image (the build CI just deployed).
#  2. bin/atlas opens the tunnel over WireGuard to Control on the private network, and
#     Control answers with the kinds of rela's description: State read it from rela.
#  3. Every kind lists: each read goes Control -> Bus -> State -> rela on Fly and back.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
env="${1:?usage: smoke.sh <env> [<image label>]}"
label="${2:-}"
fail() { echo "smoke: $*" >&2; exit 1; }
atlas() { ATLAS_NO_UPDATE=1 "$root/bin/atlas" "$@" --env "$env"; }
fly="$(command -v fly || command -v flyctl)" || fail "no flyctl"
app="$(jq -r '.fly.app // empty' "$root/env/$env.json")"
[ -n "$app" ] || fail "env/$env.json has no fly.app: $env does not run on Fly"

if [ -n "$label" ]; then
  running="$("$fly" status -a "$app" --json | jq -r '.Machines[0].image_ref.tag')"
  [ "$running" = "$label" ] || fail "$app runs $running, not $label"
  echo "smoke: $app runs $label"
fi

kinds="$(atlas help --json | jq -r '.[].kind')"
[ -n "$kinds" ] || fail "Control on $app answered no kinds"
echo "smoke: Control on $app answers over the private network; kinds: $(echo $kinds)"

for kind in $kinds; do
  count="$(atlas list "$kind" --json | jq -e 'if type == "array" then length else error("not a list") end')" ||
    fail "listing $kind failed"
  echo "smoke: $kind: $count"
done
echo "smoke: $env on Fly answers"
