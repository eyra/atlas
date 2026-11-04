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

command, root, client_file, environment = sys.argv[1:]
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


if command == "runtime-status":
    pid = alive(pidfile)
    print(f"Runtime {environment}: " + (f"running (pid {pid}); log {base / 'runtime.log'}" if pid else "stopped"))
    sys.exit(0)
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
