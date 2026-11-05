#!/usr/bin/env python3
"""Local Runtime lifecycle. No Fly settings or secrets are changed here."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time


def runtime_paths(environment):
    base = Path(os.environ.get("ATLAS_RUNTIME_HOME", str(Path.home() / ".local/share/atlas" / (environment + "-runtime")))).expanduser().resolve()
    settings = Path(os.environ.get("ATLAS_RUNTIME_FILE", str(base / "runtime.json"))).expanduser().resolve()
    return base, settings


def observe_status(root, environment, request, inspect_process=None):
    """Readonly IS91 projection. PID presence alone never establishes node ownership."""
    import importlib.util
    import re
    target = request['target']
    base, settings_file = runtime_paths(environment)
    status = dict(target=target, state='unsupported', basis='invalid_identity', message='invalid machine identity',
                  capabilities=dict(local_status=True, local_start=False, local_stop=False, remote_status=False), log=str(base/'runtime.log'))
    if target['environment'] != environment or not re.fullmatch(r'[a-zA-Z0-9_.-]+', target['machine']):
        return status
    try:
        settings = json.loads(settings_file.read_text())
        if not isinstance(settings, dict) or settings.get('env') != environment:
            return dict(status, basis='wrong_environment', message='local Runtime configuration belongs to a different or unknown environment')
        runtime = settings.get('runtime', {})
        link = settings.get('bus_link', {})
        if not isinstance(runtime, dict) or not isinstance(link, dict) or runtime.get('machine') != target['machine'] or link.get('machine') != target['machine']:
            return dict(status, basis='wrong_machine', message='selected machine does not match the local Runtime configuration')
    except FileNotFoundError:
        if (base/'runtime.pid').exists():
            return dict(status, state='unverified', basis='missing_configuration', message='retained PID has no matching machine configuration; ownership unknown')
    except (OSError, ValueError):
        return dict(status, basis='unreadable_configuration', message='local Runtime configuration is unavailable or malformed')
    try:
        pid = int((base/'runtime.pid').read_text())
        if pid <= 1:
            raise ValueError('invalid PID')
    except FileNotFoundError:
        return dict(status, state='absent', basis='no_pid_record', message='no retained local Runtime PID; remote availability is not queried')
    except (OSError, ValueError):
        return dict(status, state='stale', basis='invalid_pid_record', message='retained PID record is invalid or unreadable; ownership not established')
    # Reuse the independently reviewed OS inspector. Do not use its stop helper or
    # IS91's signal/group path, and do not infer health from executable names.
    if inspect_process is None:
        spec = importlib.util.spec_from_file_location('atlas_process_identity', Path(root)/'tools/runtime-playground/launch.py')
        inspector = importlib.util.module_from_spec(spec)
        previous = sys.dont_write_bytecode
        try:
            sys.dont_write_bytecode = True
            spec.loader.exec_module(inspector)
        finally:
            sys.dont_write_bytecode = previous
        inspect_process = inspector.process_identity
    try:
        identity = inspect_process(pid)
    except (OSError, ValueError):
        return dict(status, state='stale', basis='process_unavailable', pid=pid, message='retained process is unavailable or cannot be inspected; no Runtime claim')
    if identity['uid'] != os.getuid():
        return dict(status, state='stale', basis='owner_mismatch', pid=pid, message='retained PID belongs to another user; ownership refused')
    return dict(status, state='unverified', basis='pid_only_legacy', pid=pid, process_present=True,
                message='OS process exists, but no retained role/instance/start binding proves it is this Runtime; health and ownership unknown')


def status_cli(root, environment, options):
    # Use already-built shared codecs. A status invocation never compiles, installs,
    # creates a Runtime directory, resolves credentials or opens a proxy.
    candidates = [Path(root)/part/'_build'/mode/'lib' for part in ('bff/contract', 'beam') for mode in ('dev', 'test', 'prod')]
    build = next((path for path in candidates if (path/'atlas_bff_contract/ebin/Elixir.AtlasBFFContract.Runtime.MachineProtocol.beam').is_file()), None)
    if build is None:
        print('Runtime status: unsupported (machine status codec not built; build bff/contract first)', file=sys.stderr)
        return 2
    executable = shutil.which('elixir')
    if executable is None:
        print('Runtime status: unsupported (Elixir codec interpreter unavailable)', file=sys.stderr)
        return 2
    paths = [argument for path in sorted(build.glob('*/ebin')) for argument in ('-pa', str(path))]
    _, settings = runtime_paths(environment)
    env = dict(os.environ, ELIXIR_ERL_OPTIONS='+S 1:1', PYTHONDONTWRITEBYTECODE='1')
    return subprocess.call([executable, *paths, str(Path(root)/'tools/runtime_status.exs'), root, environment, str(settings), *options], env=env)


def main():
    command, root, client_file, environment, *options = sys.argv[1:]
    if command == 'runtime-status':
        return status_cli(root, environment, options)
    if command == '_runtime-status-observe':
        print(json.dumps(observe_status(root, environment, json.loads(options[0]))))
        return 0
    if command not in ('runtime', 'runtime-stop') or options:
        sys.exit('unsupported Runtime command; this slice adds readonly status only')

    client = json.loads(Path(client_file).read_text())
    base = Path(os.environ.get("ATLAS_RUNTIME_HOME", str(Path.home() / ".local/share/atlas" / (environment + "-runtime"))))
    base.mkdir(parents=True, exist_ok=True)
    pidfile = base / "runtime.pid"
    tunnel_pidfile = base / "tunnel.pid"


    def alive(file):
        try:
            pid = int(file.read_text())
            os.kill(pid, 0)
            return pid
        except (OSError, ValueError):
            return None


    def stop(file):
        pid = alive(file)
        if pid:
            os.killpg(pid, signal.SIGTERM)
            for _ in range(50):
                if not alive(file):
                    break
                time.sleep(0.1)
            if alive(file):
                os.killpg(pid, signal.SIGKILL)
        file.unlink(missing_ok=True)


    if command == "runtime-stop":
        stop(pidfile)
        stop(tunnel_pidfile)
        print(f"Runtime {environment}: stopped")
        sys.exit(0)
    if alive(pidfile):
        print(f"Runtime {environment}: already running")
        sys.exit(0)

    settings_file = Path(os.environ.get("ATLAS_RUNTIME_FILE", str(base / "runtime.json")))
    try:
        settings = json.loads(settings_file.read_text())
        if settings["env"] != environment:
            raise ValueError("runtime.json belongs to another environment")
        link = settings["bus_link"]
        runtime = settings["runtime"]
        if link["mode"] != "client" or runtime["machine"] != link["machine"] or not runtime["agents"]:
            raise ValueError("need a client bus_link, matching machine and nonempty runtime.agents")
        token = os.environ.get("ATLAS_BUS_LINK_TOKEN")
        if not token:
            token = subprocess.check_output(["security", "find-generic-password", "-s",
                f"atlas-bus-link-{environment}", "-a", link["machine"], "-w"], stderr=subprocess.DEVNULL).decode().strip()
        if not token:
            raise ValueError("empty Bus link token")
    except (KeyError, ValueError, OSError, subprocess.SubprocessError) as error:
        sys.exit(f"atlas runtime: {error}; see docs/guides/runtime-node.md")

    fly = client.get("fly", {})
    if fly and fly.get("in_use", True):
        if link.get("host", "127.0.0.1") != "127.0.0.1":
            sys.exit("atlas runtime: fly proxy needs bus_link.host 127.0.0.1")
        if not alive(tunnel_pidfile):
            executable = shutil.which("fly") or shutil.which("flyctl")
            if not executable:
                sys.exit("atlas runtime: install flyctl and log in first")
            with (base / "tunnel.log").open("ab") as log:
                proc = subprocess.Popen([executable, "proxy", f"{link['port']}:{link.get('remote_port', 7694 if environment == 'test' else 7594)}",
                    "-a", fly["app"], "-q"], stdout=log, stderr=log, stdin=subprocess.DEVNULL, start_new_session=True)
            tunnel_pidfile.write_text(str(proc.pid))

    child_env = dict(os.environ, ATLAS_ROOT=root, ATLAS_ENV=environment, ATLAS_ROLE="runtime",
        ATLAS_ENV_FILE=str(settings_file.resolve()), ATLAS_CLIENT_ENV_FILE=client_file, ATLAS_BUS_LINK_TOKEN=token)
    child_env.setdefault("ELIXIR_ERL_OPTIONS", "+S 2:2")
    with (base / "runtime.log").open("ab") as log:
        proc = subprocess.Popen(["mix", "run", "--no-start", "--no-halt", "runtime-node.exs"], cwd=str(Path(root) / "beam"),
            env=child_env, stdout=log, stderr=log, stdin=subprocess.DEVNULL, start_new_session=True)
    pidfile.write_text(str(proc.pid))
    for _ in range(20):
        time.sleep(0.1)
        if proc.poll() is not None:
            pidfile.unlink(missing_ok=True)
            stop(tunnel_pidfile)
            sys.exit(f"atlas runtime: failed; see {base / 'runtime.log'}")
    print(f"Runtime {environment}: started (pid {proc.pid}); log {base / 'runtime.log'}; reconnects while the Bus is unavailable")


if __name__ == "__main__":
    sys.exit(main())
