#!/usr/bin/env python3
"""Own a Codex process group; parent EOF/stop interrupts it before this helper exits."""
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time


def emit(event):
    print(json.dumps(event), flush=True)


def signal_group(process, sig):
    try:
        try:
            os.killpg(process.pid, sig)
        except PermissionError as error:
            # macOS can deny a group signal while its last member is exiting,
            # even before poll() can reap it. Bound the wait for our own leader,
            # then still signal any surviving descendants in the same group.
            # A live leader or a second denial remains a real permission error.
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                raise error
            os.killpg(process.pid, sig)
    except ProcessLookupError:
        pass


def main():
    executable, workspace, folder, goal, sandbox, session = sys.argv[1:]
    if sandbox not in ('read-only', 'workspace-write'):
        raise ValueError('Sandbox must be read-only or workspace-write')
    folder = Path(folder)
    command = [executable, 'exec', '--sandbox', sandbox, '--disable', 'hooks',
               '-c', 'forced_login_method="chatgpt"', '-c', 'approval_policy="never"',
               '--color', 'never', '--cd', workspace]
    if session:
        command.append('resume')
    command += ['--json', '--ignore-user-config', '--ignore-rules', '--skip-git-repo-check',
                '--output-last-message', str(folder / 'answer.txt'), '--']
    command += [session, goal] if session else [goal]
    session_seen = False

    def forward(event):
        nonlocal session_seen
        if event.get('type') == 'thread.started':
            identifier = event.get('thread_id')
            if not isinstance(identifier, str) or not identifier or (session and identifier != session):
                raise ValueError('Codex did not confirm the requested session')
            session_seen = True
        emit({'type': 'runtime.event', 'event': event})

    process = None
    selector = selectors.DefaultSelector()
    stopped = False
    deadline = None
    partial = b''
    stdout_open = True
    try:
        with (folder / 'stderr.log').open('wb') as errors, (folder / 'stream.jsonl').open('wb') as output:
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                       stderr=errors, start_new_session=True)
            (folder / 'process.json').write_text(json.dumps({'pid': process.pid, 'command': command}))
            emit({'type': 'runtime.process_started', 'pid': process.pid})
            selector.register(sys.stdin, selectors.EVENT_READ, 'control')
            selector.register(process.stdout, selectors.EVENT_READ, 'output')
            while True:
                for key, _ in selector.select(.1):
                    if key.data == 'control':
                        os.read(sys.stdin.fileno(), 4096)  # Any control input, including EOF, means stop.
                        selector.unregister(sys.stdin)
                        stopped = True
                        deadline = time.monotonic() + 3
                        signal_group(process, signal.SIGINT)
                    else:
                        data = os.read(process.stdout.fileno(), 65536)
                        if not data:
                            selector.unregister(process.stdout)
                            stdout_open = False
                        else:
                            output.write(data)
                            output.flush()
                            partial += data
                            while b'\n' in partial:
                                line, partial = partial.split(b'\n', 1)
                                # Keep protocol records separate from helper diagnostics.
                                event = json.loads(line)
                                forward(event)
                            if len(partial) > 1048576:
                                raise ValueError('Codex event exceeds 1 MiB')
                if deadline is not None and time.monotonic() >= deadline:
                    signal_group(process, signal.SIGKILL)
                    deadline = None
                if not stdout_open:
                    if partial.strip():
                        forward(json.loads(partial))
                        partial = b''
                    # EOF can precede the leader's exit; do not turn a clean exit into SIGKILL.
                    try:
                        code = process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        signal_group(process, signal.SIGKILL)
                        code = process.wait()
                    # A finished leader can leave descendants with redirected output.
                    signal_group(process, signal.SIGKILL)
                    if session and not session_seen and not stopped:
                        raise ValueError('Codex resume ended without confirming its session')
                    emit({'type': 'runtime.process_ended', 'exit_code': code, 'stopped': stopped})
                    return
    finally:
        selector.close()
        if process is not None and process.returncode is None:
            signal_group(process, signal.SIGKILL)
            process.wait()


if __name__ == '__main__':
    try:
        main()
    except BrokenPipeError:
        pass  # Parent disappeared; main's finally has already reaped the process.
    except Exception as error:
        print(f'Codex runner: {error}', file=sys.stderr)
        sys.exit(1)
