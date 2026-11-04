#!/usr/bin/env bash
# Closure-aware, read-only comparison and compatibility check (IS-Atlas-73/97).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
root="${ATLAS_TEST_ROOT:-$HOME/.local/share/atlas/test}"
data="${ATLAS_RELA_DATA:-$root/rela}"
bin="${ATLAS_RELA_BIN:-$root/bin}"
case "${1:-}" in
  same|fits) exec "${ATLAS_CONFIG_PYTHON:-python3}" "$here/scripts/config.py" "$1" --root "$here" --data "$data" --bin "$bin/rela" ;;
  *) echo 'usage: description.sh same|fits' >&2; exit 2 ;;
esac
