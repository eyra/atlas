#!/usr/bin/env python3
"""Own a native CLI process group; parent EOF/stop interrupts it before this helper exits."""
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import selectors
import signal
import shutil
import subprocess
import sys
import time
import tempfile
import uuid


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


def dedicated_scope(root):
    return {'profile': 'dedicated-repository', 'version': 1, 'root': str(root),
            'git_dir': str(root / '.git'), 'network_hosts': ['github.com', 'api.github.com']}


def repository_request(home, url, branch):
    match = re.fullmatch(r'https://github\.com/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9_.-]+)', url)
    if not match:
        raise ValueError('Repository must be an HTTPS github.com owner/repository URL')
    owner, name = (part.lower() for part in match.groups())
    name = name.removesuffix('.git')
    if name in ('', '.', '..'):
        raise ValueError('Invalid repository name')
    checked = subprocess.run(['git', 'check-ref-format', '--branch', branch],
                             capture_output=True, text=True)
    if checked.returncode or checked.stdout.strip() != branch or branch == 'develop':
        raise ValueError('Task branch must be a new explicit Git branch other than develop')
    root = Path(home).absolute() / 'repositories' / owner / name
    if root != root.resolve():
        raise ValueError('Managed repository path must not contain symlinks')
    return {'permissions': dedicated_scope(root),
            'repository': {'url': f'https://github.com/{owner}/{name}.git', 'branch': branch}}


def permission_scope(workspace):
    root = Path(workspace).absolute()
    if root != root.resolve() or not (root / '.git').is_dir() or (root / '.git').is_symlink():
        raise ValueError('Dedicated repository requires a canonical root with its own .git directory')
    git_dir = root / '.git'
    env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    result = subprocess.run(
        ['git', '-C', str(root), 'rev-parse', '--path-format=absolute',
         '--show-toplevel', '--git-dir', '--git-common-dir'],
        env=env, capture_output=True, text=True, check=True)
    if result.stdout.splitlines() != [str(root), str(git_dir), str(git_dir)]:
        raise ValueError('Dedicated repository cannot use worktree or external Git metadata')
    if any((git_dir / path).exists() for path in
           ('commondir', 'objects/info/alternates', 'objects/info/http-alternates', 'worktrees')):
        raise ValueError('Dedicated repository cannot share Git metadata or object stores')
    for directory, dirs, files in os.walk(git_dir):
        for name in dirs + files:
            path = Path(directory) / name
            if path.is_symlink() or (path.is_file() and path.stat().st_nlink > 1):
                raise ValueError('Dedicated Git metadata cannot contain symlinks or shared hardlinks')
    # Project config can select legacy sandbox settings instead of the explicit profile.
    ignored_config = Path(os.environ.get('CODEX_HOME', Path.home() / '.codex')).resolve() / 'config.toml'
    configs = [directory / '.codex/config.toml' for directory in (root, *root.parents)]
    configs.append(Path('/etc/codex/config.toml'))
    if any(path != ignored_config and path.exists() for path in configs):
        raise ValueError('Dedicated repository cannot load project or system Codex config')
    return dedicated_scope(root)


def permission_arguments(scope):
    root = Path(scope['root'])
    filesystem = {str(root): 'write', str(root / '.git'): 'write'}
    filesystem.update({str(root / name): 'read' for name in ('.agents', '.codex', '.aws')})
    paths = ','.join(f'{json.dumps(path)}={json.dumps(access)}' for path, access in filesystem.items())
    # One TOML table preserves quoted path keys; dotted CLI override keys do not.
    profile = ('permissions={atlas_repository={extends=":read-only",filesystem={' + paths +
               '},network={enabled=true,domains={"github.com"="allow","api.github.com"="allow"}}}}')
    return ['-c', 'default_permissions="atlas_repository"', '-c', profile,
            '-c', 'features.network_proxy=true']


def claude_repository_settings(scope, native_temporary):
    root = Path(scope['root'])
    temporary_roots = {Path(path).resolve() for path in
                       ('/tmp', '/var/tmp', tempfile.gettempdir())}
    if any(root == path or root.is_relative_to(path) for path in temporary_roots):
        raise ValueError('Claude dedicated repositories must be outside system temporary directories')
    # Claude 2.1.280 redirects longer child-temp paths to shared /tmp/claude-<uid>.
    if len(os.fsencode(Path(native_temporary) / f'claude-{os.getuid()}')) > 44:
        raise ValueError('Claude private native temp path exceeds the 44-byte child-temp limit')
    protected = [root / name for name in ('.agents', '.codex', '.aws', '.claude')]
    protected += [root / '.git/config', root / '.git/hooks']
    return {'sandbox': {
        'enabled': True, 'failIfUnavailable': True, 'allowUnsandboxedCommands': False,
        'excludedCommands': [],
        'filesystem': {'allowWrite': [str(root), str(native_temporary)],
                       'denyWrite': sorted(str(path) for path in temporary_roots) +
                                    [str(path) for path in protected]},
        'network': {'allowedDomains': scope['network_hosts'],
                    'allowAllUnixSockets': False, 'allowLocalBinding': False}}}


def lock_repository(workspace, create):
    root = Path(workspace)
    if root != root.resolve():
        raise ValueError('Repository path changed to a symlink')
    created = False
    if create:
        root.parent.mkdir(parents=True, exist_ok=True)
        try:
            root.mkdir()
            created = True
        except FileExistsError:
            pass
    if root != root.resolve():
        raise ValueError('Repository path changed to a symlink')
    lock = os.open(root, os.O_RDONLY)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(lock)
        raise ValueError('Repository already has an active Runtime owner')
    return lock, created


def claude_context(workspace, scope):
    root = Path(workspace).resolve()
    def git(*args):
        return subprocess.run(['git', '-C', str(root), *args],
                              capture_output=True, text=True)
    top = git('rev-parse', '--show-toplevel')
    identity = None
    if top.returncode == 0:
        branch = git('symbolic-ref', '--quiet', 'HEAD')
        if branch.returncode not in (0, 1):
            raise ValueError('Cannot inspect Claude repository branch')
        head = branch.stdout.strip() if branch.returncode == 0 else git('rev-parse', 'HEAD').stdout.strip()
        origin = git('config', '--get-all', 'remote.origin.url')
        if not head or origin.returncode not in (0, 1):
            raise ValueError('Cannot inspect Claude repository identity')
        identity = {'root': top.stdout.strip(), 'branch': head, 'origin': origin.stdout.splitlines()}
    elif top.returncode != 128 or any(os.path.lexists(path / '.git') for path in (root, *root.parents)):
        raise ValueError('Cannot inspect Claude working directory')
    return {'cwd': str(root), 'permissions': scope, 'git': identity}


def execute_assignment(workspace, scope, repository, created, backend, folder, expected_context, command):
    if repository is not None:
        executable = shutil.which('codex') if backend == 'claude' else command[0]
        if executable is None:
            raise ValueError('Managed repository preparation requires the installed Codex sandbox')
        prepared = prepare_repository(executable, scope, repository, created)
        emit({'type': 'runtime.repository_prepared', 'repository': prepared})
    if scope is not None and scope != permission_scope(workspace):
        raise ValueError('Dedicated repository permission scope changed')
    if backend == 'claude':
        context = claude_context(workspace, scope)
        if expected_context is not None and context != expected_context:
            raise ValueError('Saved Claude working directory, repository identity or permission scope changed')
        (Path(folder) / 'claude-context.json').write_text(json.dumps(context))
    os.execv(command[0], command)


def prepare_repository(executable, scope, repository, created):
    root = Path(scope['root'])
    url, branch = repository['url'], repository['branch']
    expected = repository_request(root.parents[2], url, branch)
    if expected != {'permissions': scope, 'repository': {'url': url, 'branch': branch}}:
        raise ValueError('Managed repository request changed')
    marker = root / '.git/atlas-runtime-repository.json'
    identity = {'version': 1, 'url': url}

    def git(*args, check=True):
        result = subprocess.run(
            [executable, 'sandbox', '-P', 'atlas_repository', '-C', str(root),
             *permission_arguments(scope), '--', 'git', '-c', 'core.hooksPath=/dev/null',
             '-c', 'core.fsmonitor=false', '-c', 'maintenance.auto=false', '-c', 'gc.auto=0',
             '-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential', *args],
            capture_output=True, text=True, env=dict(os.environ, GIT_TERMINAL_PROMPT='0'))
        if check and result.returncode:
            raise ValueError(f'Git preparation failed: {result.stderr.strip()}')
        return result

    if created:
        git('clone', '--origin', 'origin', '--branch', 'develop', url, '.')
        permission_scope(str(root))
        marker.write_text(json.dumps(identity) + '\n')
    else:
        if not marker.is_file() or json.loads(marker.read_text()) != identity:
            raise ValueError('Refusing an unmanaged or mismatched repository')
        permission_scope(str(root))
        if git('remote', 'get-url', 'origin').stdout.strip() != url:
            raise ValueError('Managed repository origin does not match the request')
    if 'base_sha' in repository:
        if git('branch', '--show-current').stdout.strip() != branch:
            raise ValueError('Saved repository branch changed; continuation will not switch it')
        return repository
    if git('status', '--porcelain', '--untracked-files=all').stdout:
        raise ValueError('Managed repository has uncommitted work; nothing was reset or stashed')
    local = git('show-ref', '--verify', '--quiet', f'refs/heads/{branch}', check=False)
    if local.returncode != 1:
        raise ValueError('Task branch already exists or cannot be checked')
    git('fetch', '--no-tags', 'origin', '+refs/heads/*:refs/remotes/origin/*')
    remote = git('show-ref', '--verify', '--quiet', f'refs/remotes/origin/{branch}', check=False)
    if remote.returncode != 1:
        raise ValueError('Task branch already exists remotely or cannot be checked')
    base = git('rev-parse', '--verify', 'refs/remotes/origin/develop^{commit}').stdout.strip()
    git('checkout', '--no-overwrite-ignore', '--no-track', '-b', branch, base)
    return {**repository, 'base_sha': base}


def codex_model(session, workspace, started_at):
    # Exec JSON omits model identity; only this invocation's native turn context is evidence.
    if not re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', session):
        return None
    home = Path(os.environ.get('CODEX_HOME', Path.home() / '.codex'))
    model = None
    try:
        for path in (home / 'sessions').glob(f'*/*/*/rollout-*-{session}.jsonl'):
            with path.open() as records:
                metadata = json.loads(next(records))
                if (metadata.get('type') != 'session_meta' or
                        metadata.get('payload', {}).get('id') != session):
                    continue
                for line in records:
                    record = json.loads(line)
                    if record.get('type') != 'turn_context':
                        continue
                    context = record.get('payload', {})
                    timestamp = datetime.fromisoformat(record.get('timestamp', '').replace('Z', '+00:00'))
                    if (timestamp.tzinfo is not None and timestamp >= started_at and
                            context.get('cwd') == workspace and
                            isinstance(context.get('model'), str) and context['model'] and
                            context['model'] != '<synthetic>'):
                        model = context['model']
    except (OSError, ValueError, TypeError, AttributeError, StopIteration):
        return None
    return model


def main():
    if len(sys.argv) == 3 and sys.argv[1] == '--workspace-path':
        print(json.dumps(str(Path(sys.argv[2]).resolve())))
        return
    if len(sys.argv) == 3 and sys.argv[1] == '--permission-scope':
        print(json.dumps(permission_scope(sys.argv[2])))
        return
    if len(sys.argv) == 5 and sys.argv[1] == '--repository-request':
        print(json.dumps(repository_request(*sys.argv[2:])))
        return
    if len(sys.argv) > 9 and sys.argv[1] == '--execute-assignment':
        execute_assignment(sys.argv[2], json.loads(sys.argv[3]), json.loads(sys.argv[4]),
                           json.loads(sys.argv[5]), sys.argv[6], sys.argv[7],
                           json.loads(sys.argv[8]), sys.argv[9:])
        return
    executable, workspace, folder, goal, sandbox, session, *extra = sys.argv[1:]
    scope = json.loads(extra[0]) if extra else None
    repository = json.loads(extra[1]) if len(extra) >= 2 else None
    backend = extra[2] if len(extra) >= 3 else 'codex'
    model = json.loads(extra[3]) if len(extra) >= 4 else None
    expected_context = json.loads(extra[4]) if len(extra) >= 5 else None
    if model is not None and (not isinstance(model, str) or
                              not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._:/\[\]-]{0,199}', model)):
        raise ValueError('Model must be a nonempty identifier of at most 200 characters')
    if backend not in ('codex', 'claude'):
        raise ValueError('Backend must be codex or claude')
    if backend == 'claude' and scope is None and sandbox != 'read-only':
        raise ValueError('Claude requires read-only or dedicated-repository execution')
    if backend == 'claude' and session:
        if str(uuid.UUID(session)) != session or model is None or not isinstance(expected_context, dict):
            raise ValueError('Claude resume requires a confirmed UUID, model and saved execution context')
    if len(extra) > 5 or (scope is None and sandbox not in ('read-only', 'workspace-write')):
        raise ValueError('Sandbox must be read-only or workspace-write')
    if repository is not None and (scope != dedicated_scope(Path(workspace)) or
                                   bool(session) != ('base_sha' in repository)):
        raise ValueError('Managed repository context does not match this start or continuation')
    if scope is not None:
        if sandbox:
            raise ValueError('Dedicated repository permissions conflict with sandbox')
        permissions = permission_arguments(scope)
    else:
        permissions = ['--sandbox', sandbox]
    folder = Path(folder)
    model_arguments = ['--model', model] if model is not None else []
    if backend == 'claude':
        tools = 'Bash,Read,Glob,Grep' if scope is not None else 'Read,Glob,Grep'
        command = [executable, '--print', '--output-format', 'stream-json', '--verbose',
                   '--restricted', '--safe-mode', '--strict-mcp-config', '--no-chrome',
                   '--tools', tools, '--allowedTools', tools,
                   '--permission-mode', 'dontAsk', '--permission-prompts', 'none',
                   *(['--resume', session] if session else []), *model_arguments, '--', goal]
    else:
        command = [executable, 'exec', *permissions, '--disable', 'hooks',
                   '-c', 'forced_login_method="chatgpt"', '-c', 'approval_policy="never"',
                   '--color', 'never', '--cd', workspace]
        if session:
            command.append('resume')
        command += [*model_arguments, '--json', '--ignore-user-config', '--ignore-rules', '--skip-git-repo-check',
                    '--output-last-message', str(folder / 'answer.txt'), '--']
        command += [session, goal] if session else [goal]
    session_seen = False
    native_session = None

    def forward(event):
        nonlocal session_seen, native_session
        if backend == 'claude' and session:
            if event.get('type') == 'system' and event.get('subtype') == 'init':
                if event.get('session_id') != session or event.get('model') != model:
                    raise ValueError('Claude did not confirm the requested session and model')
                session_seen = True
            if event.get('type') == 'assistant':
                actual = event.get('message', {}).get('model')
                if actual and actual != '<synthetic>' and actual != model:
                    raise ValueError('Claude resumed with a different model')
        if backend == 'claude' and event.get('type') == 'result' and isinstance(event.get('result'), str):
            (folder / 'answer.txt').write_text(event['result'])
        if event.get('type') == 'runtime.repository_prepared':
            emit(event)
            return
        if event.get('type') == 'thread.started':
            identifier = event.get('thread_id')
            if not isinstance(identifier, str) or not identifier or (session and identifier != session):
                raise ValueError('Codex did not confirm the requested session')
            session_seen = True
            if backend == 'codex':
                native_session = identifier
        emit({'type': 'runtime.event', 'event': event})

    process = None
    lock = None
    created = False
    native_temporary = None
    environment = None
    selector = selectors.DefaultSelector()
    stopped = False
    deadline = None
    partial = b''
    stdout_open = True
    try:
        with (folder / 'stderr.log').open('wb') as errors, (folder / 'stream.jsonl').open('wb') as output:
            if scope is not None or (Path(workspace) / '.git/atlas-runtime-repository.json').exists():
                try:
                    lock, created = lock_repository(workspace, repository is not None and not session)
                except Exception as error:
                    errors.write(str(error).encode())
                    raise
                if backend == 'claude' and scope is not None:
                    if repository is None and scope != permission_scope(workspace):
                        raise ValueError('Dedicated repository permission scope changed')
                    native_temporary = tempfile.mkdtemp(prefix='.ac-', dir=Path.home().resolve())
                    command[1:1] = ['--settings', json.dumps(
                        claude_repository_settings(scope, native_temporary))]
                    environment = dict(os.environ, CLAUDE_CODE_TMPDIR=native_temporary)
            if scope is not None or backend == 'claude':
                command = [sys.executable, str(Path(__file__).resolve()), '--execute-assignment',
                           workspace, json.dumps(scope), json.dumps(repository), json.dumps(created),
                           backend, str(folder), json.dumps(expected_context), *command]
            started_at = datetime.now(timezone.utc)
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                       stderr=errors, start_new_session=True,
                                       cwd=workspace if backend == 'claude' else None, env=environment)
            (folder / 'process.json').write_text(json.dumps({
                'pid': process.pid, 'command': command, 'native_temporary': native_temporary}))
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
                        raise ValueError(f'{backend.capitalize()} resume ended without confirming its session')
                    if backend == 'codex' and native_session and not stopped:
                        actual_model = codex_model(native_session, workspace, started_at)
                        if actual_model:
                            emit({'type': 'runtime.identity', 'backend': 'codex', 'model': actual_model})
                    emit({'type': 'runtime.process_ended', 'exit_code': code, 'stopped': stopped})
                    return
    finally:
        selector.close()
        if process is not None and process.returncode is None:
            signal_group(process, signal.SIGKILL)
            process.wait()
        if native_temporary is not None:
            try:
                shutil.rmtree(native_temporary)
            except FileNotFoundError:
                pass
        # Keep ownership until the complete process group has been reaped, including on stop.
        if lock is not None:
            os.close(lock)


if __name__ == '__main__':
    try:
        main()
    except BrokenPipeError:
        pass  # Parent disappeared; main's finally has already reaped the process.
    except Exception as error:
        print(f'Native runner: {error}', file=sys.stderr)
        sys.exit(1)
