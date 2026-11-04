# Versioned description

`schema.yaml` selects native rela 26.10.14 includes. Foundation owns actors,
Assignments and turns; optional foundation audit owns requests/steps; software
factory owns Issue/PR and compatibility fields; Eyra owns Scene/Use Case and
hierarchy/acceptance. The composition owns the complete `assignment` relation.
Includes are relative to the selected schema root, including nested includes.
Every definition has one owner; no overrides or property augmentation.

Operational scripts require Python 3.9+ and PyYAML. In a virtual environment:

```sh
python3 -m venv ~/.local/share/atlas/config-python
~/.local/share/atlas/config-python/bin/pip install -r rela/scripts/requirements.txt
export ATLAS_CONFIG_PYTHON="$HOME/.local/share/atlas/config-python/bin/python"
```

CI installs the pinned requirement; the rela image uses Debian's `python3-yaml`.
Startup copies the selected closure, comparison checks every included byte, and
fits scans a private data copy against the resolved description. Old included
files may remain on disk, but only the selected closure is loaded. Data folders
are never part of packaging. Fly preflight uses a resolved flat equivalent so it
also works against the previous deployed image, which has no Python. The new
image starts rela with native includes. No data migration is needed.

Run `python3 -m unittest discover -s rela/tests -v`, pinned `rela --project rela
validate`, and private e2e before delivery. `tests/fixtures/baseline-schema.yaml`
is the delivered #79 schema: tests lock definitions and property/form order.
`atlas.json` remains the single extension consumed by State.
