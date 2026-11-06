#!/usr/bin/env python3
"""Create, attach to, or shut down a private independently running Runtime."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


def client(directory, mode, words=()):
    directory = directory.expanduser().resolve()
    paths = [arg for path in sorted((directory / 'build/lib').glob('*/ebin'))
             for arg in ('-pa', str(path))]
    if not paths or not (directory / 'ready').is_file():
        raise RuntimeError(f'No ready private Runtime at {directory}; nothing was started')
    argv = ['elixir', *paths, str(ROOT / 'tools/runtime-playground/terminal.exs'),
            mode, str(directory)]
    if mode != 'shutdown':
        argv.extend(['breaker', *words])
    return subprocess.call(argv, env=runtime_env(directory))


def runtime_env(directory):
    env = {key: value for key, value in os.environ.items() if not key.startswith('ATLAS_')}
    env.update(MIX_ENV='test', ELIXIR_ERL_OPTIONS='+S 2:2',
               MIX_BUILD_PATH=str(directory / 'build'))
    return env


def prepare(args):
    binary = Path.home() / '.local/share/atlas/test/bin/rela-server'
    if not binary.is_file():
        raise RuntimeError(f'Cached Rela binary required: {binary}; nothing will be downloaded')
    # Keep AF_UNIX paths below macOS's sockaddr_un limit, including /private prefix.
    directory = (args.directory.expanduser() if args.directory else
                 Path(tempfile.mkdtemp(prefix='atlas-runtime-', dir='/tmp'))).resolve()
    if len(os.fsencode(directory / 'runtime.sock')) > 100:
        raise RuntimeError('Choose a shorter directory: socket path must be at most 100 bytes')
    if args.directory:
        directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    settings = {'port': args.agent}
    if args.agent == 'codex':
        executable = shutil.which('codex')
        if not executable:
            raise RuntimeError('Codex must be installed and signed in using codex login')
        workspace = directory / 'workspace'
        workspace.mkdir()
        (workspace / 'sample.py').write_text('def total_with_tax(prices, rate):\n    return round(sum(prices) * (1 + rate), 2)\n')
        settings.update(command=executable, workspace=str(workspace), goal=args.goal)
    (directory / 'worker.json').write_text(json.dumps(settings))
    env = runtime_env(directory)
    python = ROOT / '.venv-config/bin/python'
    if not python.is_file():
        python = Path(sys.executable)
    subprocess.run([str(python), str(ROOT / 'rela/scripts/config.py'), 'copy', '--root', str(ROOT / 'rela'), '--data', str(directory / 'rela')], env=env, check=True)
    subprocess.run(['mix', 'compile', '--warnings-as-errors'], cwd=ROOT / 'beam', env=env, check=True)
    return directory


def terminate(child):
    if child is not None and child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


def serve(directory):
    env = runtime_env(directory)
    binary = Path.home() / '.local/share/atlas/test/bin/rela-server'
    controller = rela = None

    def interrupted(_signal, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    with (directory / 'rela.log').open('wb') as log:
        rela = subprocess.Popen([str(binary), '-project', str(directory / 'rela'), '-bind', '127.0.0.1', '-port', str(port), '-quiet'], stdout=log, stderr=subprocess.STDOUT, env=env)
        try:
            for _ in range(100):
                if rela.poll() is not None:
                    raise RuntimeError(f'Rela exited; inspect {directory / "rela.log"}')
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.1):
                        break
                except OSError:
                    time.sleep(.1)
            else:
                raise RuntimeError('Private Rela startup timed out')
            print(f'Private data: {directory}', flush=True)
            controller = subprocess.Popen(
                ['mix', 'run', '--no-compile', '--no-deps-check',
                 str(ROOT / 'tools/runtime-playground/console.exs'), str(directory), str(port)],
                cwd=ROOT / 'beam', env=env, stdin=subprocess.DEVNULL)
            (directory / 'processes.json').write_text(json.dumps({
                'supervisor': os.getpid(), 'controller': controller.pid, 'rela': rela.pid}))
            while controller.poll() is None:
                if rela.poll() is not None:
                    raise RuntimeError('Private Rela exited; closing its Runtime, not restarting it')
                time.sleep(.1)
            return controller.returncode
        finally:
            # Only Popen children of this supervisor are signalled, never stale PID files.
            terminate(controller)
            terminate(rela)
            (directory / 'ready').unlink(missing_ok=True)
            (directory / 'runtime.sock').unlink(missing_ok=True)
            (directory / 'closed').write_text('Private processes reaped; data preserved\n')
            print(f'Private instance closed. Data preserved: {directory}', flush=True)


def launch(directory):
    with (directory / 'server.log').open('wb') as log:
        child = subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), '--serve', str(directory)],
            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
            start_new_session=True, env=runtime_env(directory))
    try:
        for _ in range(300):
            if child.poll() is not None:
                raise RuntimeError(f'Private Runtime exited; inspect {directory / "server.log"}')
            if (directory / 'ready').is_file():
                print(f'Private data: {directory}\n'
                      'Runtime lifetime is independent of this terminal.\n'
                      f'Attach: python3 tools/runtime-playground/run.py --attach {directory}\n'
                      f'Shut down: python3 tools/runtime-playground/run.py --shutdown {directory}',
                      flush=True)
                return
            time.sleep(.1)
        raise RuntimeError(f'Private Runtime startup timed out; inspect {directory / "server.log"}')
    except BaseException:
        terminate(child)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--attach', type=Path, metavar='DIR')
    mode.add_argument('--shutdown', type=Path, metavar='DIR')
    mode.add_argument('--probe', type=Path, metavar='DIR')
    mode.add_argument('--serve', type=Path, help=argparse.SUPPRESS)
    parser.add_argument('--directory', type=Path, help='new short directory; existing paths refused')
    parser.add_argument('--agent', choices=('stub', 'codex'), default='stub')
    parser.add_argument('--goal', default='Read the sample project and explain what it does. Do not change files.')
    parser.add_argument('--background', action='store_true', help='create a stopped Runtime without attaching')
    parser.add_argument('words', nargs=argparse.REMAINDER, help='probe command or exact attachment options')
    args = parser.parse_args()
    if args.words[:1] == ['--']:
        args.words = args.words[1:]
    if args.serve:
        return serve(args.serve.resolve())
    if args.attach:
        return client(args.attach, 'attach', args.words)
    if args.probe:
        if not args.words:
            parser.error('--probe requires a command such as status, start or stop')
        return client(args.probe, 'probe', args.words)
    if args.shutdown:
        directory = args.shutdown.expanduser().resolve()
        result = client(directory, 'shutdown')
        if result != 0:
            return result
        for _ in range(150):
            if (directory / 'closed').is_file():
                print(f'Private processes reaped. Data preserved: {directory}')
                return 0
            time.sleep(.1)
        raise RuntimeError('Shutdown acknowledged but process cleanup not confirmed; inspect server.log')
    if args.words:
        parser.error('Unexpected command; use --probe DIR COMMAND')
    directory = prepare(args)
    launch(directory)
    return 0 if args.background else client(directory, 'attach')


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(f'Runtime playground: {error}')
    except KeyboardInterrupt:
        sys.exit(130)
