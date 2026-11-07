"""Owned-process cleanup regressions; injected permission errors are labelled."""
import errno
import fcntl
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


HELPER = Path(__file__).resolve().parents[1] / 'priv' / 'codex_runner.py'
spec = importlib.util.spec_from_file_location('codex_runner', HELPER)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


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
