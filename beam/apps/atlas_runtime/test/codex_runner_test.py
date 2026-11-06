"""Real-process regressions for runner cleanup; no Codex/model or daemon needed."""
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


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


if __name__ == '__main__':
    unittest.main()
