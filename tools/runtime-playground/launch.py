#!/usr/bin/env python3
"""Private IS125 prototype launcher. No live environment settings are read."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'tools/runtime-playground/playground.exs'
ENV = dict(os.environ, MIX_ENV='test', ELIXIR_ERL_OPTIONS='+S 1:1')
# Private configuration only. No inherited model, Bus link or live environment file.
for key in list(ENV):
    if key.startswith('ATLAS_'):
        del ENV[key]


def beam(*args, no_start=False):
    if no_start:
        paths = [arg for path in (ROOT/'beam/_build/test/lib').glob('*/ebin') for arg in ('-pa', str(path))]
        return ['elixir', *paths, str(SCRIPT), *map(str, args)]
    return ['mix', 'run', '--no-compile', '--no-deps-check', *(['--no-start'] if no_start else []), str(SCRIPT), *map(str, args)]


def main():
    args = sys.argv[1:]
    if len(args) < 3 or args[0] not in ('playground', 'attach'):
        raise ValueError('prototype: atlas playground init|stop|probe DIR [COMMAND ...]; atlas attach WORKER --prototype DIR')
    if args[0] == 'attach':
        if len(args) != 4 or args[2] != '--prototype':
            raise ValueError('prototype: atlas attach breaker --prototype DIR')
        return subprocess.call(beam('attach', Path(args[3]).resolve(), args[1], no_start=True), cwd=ROOT/'beam', env=ENV)
    action, directory, *words = args[1:]
    directory = Path(directory).expanduser().resolve()
    if action == 'init':
        if directory.exists() or len(str(directory)) > 75:
            raise ValueError('choose a fresh private directory with a path of at most 75 characters')
        cache = Path(os.environ.get('ATLAS_E2E_RELA_BIN', str(Path.home()/'.local/share/atlas/test/bin')))
        binary = cache/'rela-server'
        if not binary.is_file():
            raise ValueError('cached rela-server required; this prototype never downloads dependencies')
        directory.mkdir(mode=0o700, parents=True)
        python = os.environ.get('ATLAS_CONFIG_PYTHON', '/usr/bin/python3')
        subprocess.run([python, str(ROOT/'rela/scripts/config.py'), 'copy', '--root', str(ROOT/'rela'), '--data', str(directory/'rela')], check=True)
        subprocess.run(['mix', 'compile', '--warnings-as-errors'], cwd=ROOT/'beam', env=ENV, check=True)
        with (directory/'server.log').open('wb') as log:
            child = subprocess.Popen(beam('server', directory, binary), cwd=ROOT/'beam', env=ENV, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        (directory/'server.pid').write_text(str(child.pid))
        for _ in range(100):
            if (directory/'ready').exists():
                print(f'PRIVATE STUB ready: {directory}\nAttach: {ROOT}/bin/atlas attach breaker --prototype {directory}\nStop instance: {ROOT}/bin/atlas playground stop {directory}')
                return 0
            if child.poll() is not None:
                raise ValueError((directory/'server.log').read_text()[-5000:])
            time.sleep(.1)
        raise ValueError(f'private startup timed out; inspect {directory}/server.log and stop this instance')
    if not (directory/'server.pid').exists():
        raise ValueError('not a ready private playground directory')
    if action == 'stop':
        # Verify retained PIDs before touching processes; never match a shared instance.
        for filename in ('server.pid', 'rela.pid'):
            pid = int((directory/filename).read_text())
            command = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], text=True, capture_output=True).stdout
            if str(directory) in command and ('playground.exs' in command or 'rela-server' in command):
                os.kill(pid, signal.SIGTERM)
        (directory/'ready').unlink(missing_ok=True)
        print(f'Private instance stopped; evidence preserved at {directory}')
        return 0
    if action == 'probe' and words:
        return subprocess.call(beam('probe', directory, 'breaker', *words, no_start=True), cwd=ROOT/'beam', env=ENV)
    raise ValueError('supported actions: init, stop, probe')


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f'playground: {error}')
