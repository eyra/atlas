#!/usr/bin/env bash
# The core of an Atlas environment on Fly (Bus, State, Flow, Control): the release, with
# State's own data on the volume (/data/beam) and the settings of fly/<env>/core.json.
set -euo pipefail

/app/fly/apply-move.sh beam

exec /app/release/bin/atlas start
