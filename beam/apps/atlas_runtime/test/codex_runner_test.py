"""Owned-process cleanup regressions; injected permission errors are labelled."""
import errno
from datetime import datetime, timezone
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


HELPER = Path(__file__).resolve().parents[1] / 'priv' / 'native_runner.py'
spec = importlib.util.spec_from_file_location('native_runner', HELPER)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class ClaudeRepositoryLifecycleTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix='.runtime-claude-scope-', dir=Path.home())
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name).resolve()
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        self.scope = runner.permission_scope(str(self.repo))
        self.capture = self.root / 'owned-temp.txt'
        self.native = self.root / 'fixture-native'

    def launch(self, scope, hang=False):
        self.native.write_text(
            f'#!{sys.executable}\n'
            'import os, time\nfrom pathlib import Path\n'
            f'Path({str(self.capture)!r}).write_text(os.environ["CLAUDE_CODE_TMPDIR"])\n'
            'print(\'{"type":"fixture.ready"}\', flush=True)\n' +
            ('time.sleep(30)\n' if hang else ''))
        self.native.chmod(0o700)
        return subprocess.Popen(
            [sys.executable, str(HELPER), str(self.native), str(self.repo), str(self.root),
             'fixture lifecycle only', '', '', json.dumps(scope), 'null', 'claude'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def test_owned_repository_temp_is_removed_after_completion_and_stop(self):
        for stop in (False, True):
            with self.subTest(stop=stop):
                process = self.launch(self.scope, hang=stop)
                try:
                    self.assertEqual(json.loads(process.stdout.readline())['type'], 'runtime.process_started')
                    self.assertEqual(json.loads(process.stdout.readline())['event']['type'], 'fixture.ready')
                    temporary = Path(self.capture.read_text())
                    self.assertEqual(temporary.parent, self.repo / '.git')
                    if stop:
                        process.stdin.write('stop\n')
                        process.stdin.flush()
                    process.wait(timeout=5)
                    _, error = process.communicate()
                    self.assertEqual(process.returncode, 0, error)
                    self.assertFalse(temporary.exists())
                    subprocess.run(['git', '-C', str(self.repo), 'rev-parse', '--git-dir'],
                                   check=True, capture_output=True)
                finally:
                    if process.poll() is None:
                        process.stdin.close()
                        process.wait(timeout=5)
                    for stream in (process.stdin, process.stdout, process.stderr):
                        stream.close()

    def test_changed_scope_never_executes_native_cli(self):
        process = self.launch({**self.scope, 'network_hosts': ['example.com']})
        try:
            process.wait(timeout=5)
            _, error = process.communicate()
            self.assertNotEqual(process.returncode, 0)
            self.assertIn('permission scope changed', error)
            self.assertFalse(self.capture.exists())
        finally:
            if process.poll() is None:
                process.stdin.close()
                process.wait(timeout=5)
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()

    def test_system_temp_repository_cannot_bypass_native_temp_denial(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, 'outside system temporary directories'):
                runner.claude_repository_settings(runner.dedicated_scope(Path(directory).resolve()))


class NativeModelTest(unittest.TestCase):
    session = '01a1b578-c3b5-7972-9664-1d250bf64cdf'

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix='runtime-model-')
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name).resolve()
        self.home = self.root / 'codex'
        self.artifact = (self.home / 'sessions/2026/11/07' /
                         f'rollout-2026-11-07T11-05-53-{self.session}.jsonl')
        self.artifact.parent.mkdir(parents=True)
        self.started = datetime(2026, 11, 7, 10, 5, 54, tzinfo=timezone.utc)
        self.environment = patch.dict(os.environ, CODEX_HOME=str(self.home))
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def records(self, *contexts, session=None):
        records = [{'type': 'session_meta', 'payload': {'id': session or self.session}}]
        records.extend({'type': 'turn_context', 'timestamp': timestamp,
                        'payload': {'cwd': cwd, 'model': model}}
                       for timestamp, cwd, model in contexts)
        self.artifact.write_text(''.join(json.dumps(record) + '\n' for record in records))

    def model(self):
        return runner.codex_model(self.session, str(self.root), self.started)

    def test_native_turn_context_not_requested_model_confirms_identity(self):
        # Shape and model from native Codex 0.166.0 rollout, with fixture-only cwd.
        self.records(('2026-11-07T10:05:55.213Z', str(self.root), 'gpt-6.1-sol'))
        self.assertEqual(self.model(), 'gpt-6.1-sol')

    def test_resume_ignores_previous_turn_and_other_workspaces(self):
        self.records(
            ('2026-11-07T10:05:53.848Z', str(self.root), 'old-model'),
            ('2026-11-07T10:05:55.213Z', '/other', 'foreign-model'))
        self.assertIsNone(self.model())
        self.records(
            ('2026-11-07T10:05:53.848Z', str(self.root), 'old-model'),
            ('2026-11-07T10:05:55.213Z', str(self.root), 'native-current'))
        self.assertEqual(self.model(), 'native-current')

    def test_missing_unconfirmed_and_malformed_artifacts_leave_identity_unknown(self):
        self.assertIsNone(self.model())
        self.records(('2026-11-07T10:05:55.213Z', str(self.root), 'model'),
                     session='different-session')
        self.assertIsNone(self.model())
        for timestamp, model in [('bad-date', 'model'), ('2026-11-07T10:05:55', 'model'),
                                 ('2026-11-07T10:05:55Z', None),
                                 ('2026-11-07T10:05:55Z', '<synthetic>')]:
            self.records((timestamp, str(self.root), model))
            self.assertIsNone(self.model())
        self.artifact.write_text('{truncated')
        self.assertIsNone(self.model())
        self.assertIsNone(runner.codex_model('../../*', str(self.root), self.started))

    def launch(self, extra, session='', artifact=False):
        native = self.root / 'native'
        native.write_text(
            f'#!{sys.executable}\n'
            'import json, sys\nfrom pathlib import Path\n'
            'from datetime import datetime, timezone\n'
            f'Path({str(self.root / "argv.json")!r}).write_text(json.dumps(sys.argv[1:]))\n' +
            (f'with Path({str(self.artifact)!r}).open("a") as output:\n'
             '    output.write(json.dumps({"type": "turn_context", '
             '"timestamp": datetime.now(timezone.utc).isoformat(), '
             f'"payload": {{"cwd": {str(self.root)!r}, "model": "native-confirmed"}}}}) + "\\n")\n'
             if artifact else '') +
            f'print(json.dumps({{"type": "thread.started", "thread_id": {self.session!r}}}), flush=True)\n'
            'print(\'{"type":"turn.completed"}\', flush=True)\n')
        native.chmod(0o700)
        process = subprocess.Popen(
            [sys.executable, str(HELPER), str(native), str(self.root), str(self.root),
             '--prompt stays one argument', 'read-only', session, *extra],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            process.wait(timeout=5)  # Keep control stdin open; EOF would cancel the turn.
            output, error = process.communicate()
            return process.returncode, [json.loads(line) for line in output.splitlines()], error
        finally:
            if process.poll() is None:
                process.stdin.close()
                process.wait(timeout=5)
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()

    def test_invalid_models_never_launch_native_process(self):
        for model in ('', '--dangerously-skip-permissions', 'opus --tools Bash', 'opus\nx',
                      'opus;touch /tmp/injected', 'x' * 201, 1, ['opus']):
            with self.subTest(model=model):
                code, events, error = self.launch(['null', 'null', 'codex', json.dumps(model)])
                self.assertEqual(code, 1)
                self.assertIn('Model must be', error)
                self.assertEqual(events, [])
                self.assertFalse((self.root / 'argv.json').exists())

    def test_current_native_artifact_emits_identity_before_process_end_on_resume(self):
        self.records(('2026-11-07T10:05:53.848Z', str(self.root), 'stale-model'))
        code, events, error = self.launch(
            ['null', 'null', 'codex', '"requested-model"'], self.session, artifact=True)
        self.assertEqual(code, 0, error)
        self.assertEqual(events[-2],
                         {'type': 'runtime.identity', 'backend': 'codex', 'model': 'native-confirmed'})
        self.assertEqual(events[-1]['type'], 'runtime.process_ended')


@unittest.skipUnless(os.name == 'posix', 'Runner process groups require POSIX')
class CleanupTest(unittest.TestCase):
    def wait_zombie(self, pid):
        # Do not poll/wait the Popen here: the regression requires an unreaped leader.
        for _ in range(200):
            state = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='],
                                   capture_output=True, text=True, check=False).stdout.strip()
            if state.startswith('Z'):
                return
            time.sleep(.01)
        self.fail(f'Owned leader {pid} did not become a zombie')

    def assert_dead(self, pid):
        for _ in range(200):
            state = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='],
                                   capture_output=True, text=True, check=False).stdout.strip()
            if not state or state.startswith('Z'):
                return
            time.sleep(.01)
        self.fail(f'Owned descendant {pid} is still running')

    def test_signalling_unreaped_exited_leader_does_not_mask_failure(self):
        process = subprocess.Popen(['/bin/sh', '-c', 'exit 0'], start_new_session=True)
        try:
            self.wait_zombie(process.pid)
            runner.signal_group(process, signal.SIGKILL)
            self.assertEqual(process.wait(timeout=5), 0)
            self.assert_dead(process.pid)
        finally:
            process.wait(timeout=5)

    def test_exited_leader_does_not_exempt_live_descendants_from_cleanup(self):
        process = subprocess.Popen(
            ['/bin/sh', '-c', 'sleep 60 </dev/null >/dev/null 2>&1 & echo $!'],
            stdout=subprocess.PIPE, text=True, start_new_session=True)
        try:
            child = int(process.stdout.readline())
            self.wait_zombie(process.pid)
            runner.signal_group(process, signal.SIGKILL)
            self.assertEqual(process.wait(timeout=5), 0)
            self.assert_dead(child)
        finally:
            # Reap the leader before final cleanup so a failing regression cannot
            # itself leave an unreaped child or a sleeping owned descendant.
            process.wait(timeout=5)
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.stdout.close()

    def test_denied_signal_to_live_leader_fails_within_bound(self):
        # The child outlives the cleanup bound but self-expires if waiting regresses.
        # Never try to cause a real EPERM by signalling a foreign process.
        process = subprocess.Popen(['/bin/sleep', '10'], start_new_session=True)
        try:
            started = time.monotonic()
            with patch.object(runner.os, 'killpg',
                              side_effect=PermissionError(errno.EPERM, 'injected denial')):
                with self.assertRaises(PermissionError):
                    runner.signal_group(process, signal.SIGKILL)
            self.assertLess(time.monotonic() - started, 6)
            self.assertIsNone(process.poll(), 'Permission failure must not claim the leader exited')
        finally:
            process.kill()
            process.wait(timeout=5)

    def test_persistent_denial_after_reaping_is_not_cleanup_success(self):
        process = subprocess.Popen(['/bin/sh', '-c', 'exit 0'], start_new_session=True)
        try:
            self.wait_zombie(process.pid)
            # Keep denying even after wait() reaps the owned leader. ESRCH is
            # harmless, but this second EPERM must remain a visible failure.
            with patch.object(runner.os, 'killpg',
                              side_effect=PermissionError(errno.EPERM, 'injected denial')):
                with self.assertRaises(PermissionError):
                    runner.signal_group(process, signal.SIGKILL)
            self.assertEqual(process.returncode, 0, 'Owned leader must still be reaped')
            self.assert_dead(process.pid)
        finally:
            process.wait(timeout=5)

    def test_runner_reports_original_native_session_failure(self):
        with tempfile.TemporaryDirectory(prefix='runtime-cleanup-') as folder:
            root = Path(folder)
            native = root / 'native'
            native.write_text(
                '#!/bin/sh\n'
                'printf \'%s\\n\' \'{"type":"thread.started","thread_id":"wrong-session"}\'\n'
                'printf \'%s\\n\' \'{"type":"turn.completed"}\'\n')
            native.chmod(0o700)
            process = subprocess.Popen(
                [sys.executable, str(HELPER), str(native), folder, folder,
                 'bounded session mismatch', 'read-only', 'expected-session'],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True)
            try:
                # Keep control stdin open until failure; communicate() first would
                # request cancellation and test a different lifecycle transition.
                process.wait(timeout=5)
                output, error = process.communicate()
                self.assertEqual(process.returncode, 1)
                self.assertIn('Codex did not confirm the requested session', error)
                self.assertNotIn('Operation not permitted', error)
                self.assertNotIn('runtime.process_ended', output)
            finally:
                if process.poll() is None:
                    process.stdin.close()
                    process.wait(timeout=5)
                for stream in (process.stdin, process.stdout, process.stderr):
                    stream.close()


class DedicatedRepositoryTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix='runtime-repository-')
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name).resolve()
        self.repo = self.root / 'repo'
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=Test',
                        '-c', 'user.email=test@example.invalid', 'commit',
                        '--allow-empty', '-qm', 'initial'], check=True)

    def test_only_independent_canonical_repository_root_is_accepted(self):
        scope = runner.permission_scope(str(self.repo))
        self.assertEqual(scope['root'], str(self.repo))
        self.assertEqual(scope['git_dir'], str(self.repo / '.git'))
        alias = self.root / 'alias'
        alias.symlink_to(self.repo, target_is_directory=True)
        child = self.repo / 'child'
        child.mkdir()
        worktree = self.root / 'worktree'
        subprocess.run(['git', '-C', str(self.repo), 'worktree', 'add', '-q',
                        '-b', 'other', str(worktree)], check=True)
        for path in (alias, child, worktree, self.repo):
            with self.subTest(path=path), self.assertRaises(ValueError):
                runner.permission_scope(str(path))

    def test_external_and_shared_metadata_are_rejected(self):
        metadata = self.repo / '.git'
        alternate = metadata / 'objects/info/alternates'
        alternate.write_text(str(self.root / 'objects') + '\n')
        with self.assertRaises(ValueError):
            runner.permission_scope(str(self.repo))
        alternate.unlink()
        linked = metadata / 'linked'
        linked.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError):
            runner.permission_scope(str(self.repo))
        linked.unlink()
        os.link(metadata / 'HEAD', self.root / 'shared-head')
        with self.assertRaises(ValueError):
            runner.permission_scope(str(self.repo))

    def test_project_config_cannot_override_permission_profile(self):
        for directory in (self.repo, self.root):
            config = directory / '.codex'
            config.mkdir()
            (config / 'config.toml').write_text('sandbox_mode = "read-only"\n')
            with self.assertRaises(ValueError):
                runner.permission_scope(str(self.repo))
            (config / 'config.toml').unlink()
            config.rmdir()


class ProvisioningTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix='runtime-provision-')
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name).resolve()
        self.source = self.root / 'source'
        self.url = 'https://github.com/test/fixture.git'
        self.git(self.root, 'init', '-q', '-b', 'develop', str(self.source))
        (self.source / 'state.txt').write_text('base\n')
        self.git(self.source, 'add', 'state.txt')
        self.git(self.source, 'commit', '-qm', 'base')
        # Local Git transport bridge: real clone/fetch/checkout, not native sandbox proof.
        self.bridge = self.root / 'local-git'
        self.bridge.write_text(
            f'#!{sys.executable}\nimport os, sys\n'
            "args = sys.argv[sys.argv.index('--') + 1:]\n"
            "os.chdir(sys.argv[sys.argv.index('-C') + 1])\n"
            "if 'clone' in args or 'fetch' in args:\n"
            f"    args[1:1] = ['-c', 'url.{self.source.as_uri()}.insteadOf={self.url}']\n"
            "os.execvp(args[0], args)\n")
        self.bridge.chmod(0o700)
        self.request = runner.repository_request(str(self.root / 'runtime'), self.url, 'task/first')
        self.repo = Path(self.request['permissions']['root'])
        self.repo.mkdir(parents=True)
        runner.prepare_repository(str(self.bridge), self.request['permissions'],
                                  self.request['repository'], True)

    def git(self, cwd, *args):
        return subprocess.check_output(
            ['git', '-C', str(cwd), '-c', 'user.name=Test',
             '-c', 'user.email=test@example.invalid', *args], text=True).strip()

    def prepare(self, branch):
        request = runner.repository_request(str(self.root / 'runtime'), self.url, branch)
        return runner.prepare_repository(str(self.bridge), request['permissions'],
                                         request['repository'], False)

    def test_reuse_uses_fresh_develop_and_preserves_prior_task_commit(self):
        self.git(self.repo, 'commit', '--allow-empty', '-qm', 'task change')
        previous = self.git(self.repo, 'rev-parse', 'HEAD')
        self.git(self.source, 'commit', '--allow-empty', '-qm', 'new develop')
        latest = self.git(self.source, 'rev-parse', 'HEAD')
        prepared = self.prepare('task/second')
        self.assertEqual(prepared['base_sha'], latest)
        self.assertEqual(self.git(self.repo, 'rev-parse', 'HEAD'), latest)
        self.assertEqual(self.git(self.repo, 'branch', '--show-current'), 'task/second')
        self.assertEqual(self.git(self.repo, 'rev-parse', 'task/first'), previous)

    def test_continuation_preserves_work_and_refuses_branch_drift(self):
        head = self.git(self.repo, 'rev-parse', 'HEAD')
        saved = {**self.request['repository'], 'base_sha': head}
        (self.repo / 'unfinished.txt').write_text('keep working\n')
        self.git(self.source, 'commit', '--allow-empty', '-qm', 'new remote base')
        runner.prepare_repository(str(self.bridge), self.request['permissions'], saved, False)
        self.assertEqual(self.git(self.repo, 'rev-parse', 'HEAD'), head)
        self.git(self.repo, 'checkout', '-qb', 'different-task')
        with self.assertRaises(ValueError):
            runner.prepare_repository(str(self.bridge), self.request['permissions'], saved, False)
        self.assertEqual(self.git(self.repo, 'branch', '--show-current'), 'different-task')
        self.assertEqual((self.repo / 'unfinished.txt').read_text(), 'keep working\n')

    def test_dirty_and_existing_branches_are_preserved(self):
        head = self.git(self.repo, 'rev-parse', 'HEAD')
        for name in ('state.txt', 'untracked.txt'):
            path = self.repo / name
            original = path.read_bytes() if path.exists() else None
            path.write_text('keep my work\n')
            with self.assertRaises(ValueError):
                self.prepare('task/second')
            self.assertEqual(path.read_text(), 'keep my work\n')
            self.assertEqual(self.git(self.repo, 'rev-parse', 'HEAD'), head)
            if original is None:
                path.unlink()
            else:
                path.write_bytes(original)
        with self.assertRaises(ValueError):
            self.prepare('task/first')
        self.git(self.source, 'branch', 'task/remote')
        with self.assertRaises(ValueError):
            self.prepare('task/remote')
        self.assertEqual(self.git(self.repo, 'branch', '--show-current'), 'task/first')
        self.assertEqual(self.git(self.repo, 'rev-parse', 'HEAD'), head)

    def test_mismatched_and_unmanaged_paths_are_preserved(self):
        self.git(self.repo, 'remote', 'set-url', 'origin', 'https://github.com/other/repo.git')
        with self.assertRaises(ValueError):
            self.prepare('task/second')
        self.assertEqual(self.git(self.repo, 'remote', 'get-url', 'origin'),
                         'https://github.com/other/repo.git')
        marker = self.repo / '.git/atlas-runtime-repository.json'
        marker.unlink()
        with self.assertRaises(ValueError):
            self.prepare('task/second')
        self.assertEqual((self.repo / 'state.txt').read_text(), 'base\n')

    def test_active_owner_blocks_reacquisition_until_release(self):
        lock = os.open(self.repo, os.O_RDONLY)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(ValueError):
                runner.lock_repository(str(self.repo), False)
        finally:
            os.close(lock)
        acquired, created = runner.lock_repository(str(self.repo), False)
        self.assertFalse(created)
        os.close(acquired)

    def test_untrusted_repository_and_branch_inputs_are_rejected(self):
        for url, branch in (
                ('file:///tmp/repo', 'task/new'), ('https://example.com/test/repo', 'task/new'),
                ('https://github.com/test/../repo', 'task/new'),
                (self.url, 'develop'), (self.url, '../branch'), (self.url, '--force')):
            with self.subTest(url=url, branch=branch), self.assertRaises(ValueError):
                runner.repository_request(str(self.root / 'runtime'), url, branch)


if __name__ == '__main__':
    unittest.main()
