"""No signals: process inspection and signalling are mocked in these regressions."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('launch', Path(__file__).with_name('launch.py'))
launch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launch)


class StopTest(unittest.TestCase):
    def test_exact_roles_instance_and_start_identity_are_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            binary = Path('/cache/rela-server')
            def identity(pid, role, start='start-1', instance=directory):
                argv = ([str(launch.SCRIPT), 'server', str(instance), str(binary)] if role == 'server'
                        else [str(binary), '-project', str(instance/'rela'), '-bind', '127.0.0.1', '-port', '1234', '-quiet'])
                return dict(pid=pid, start=start, uid=launch.os.getuid(), exe='/erlang/beam.smp' if role == 'server' else str(binary), argv=argv)
            retained = {'server': identity(111, 'server'), 'rela': identity(222, 'rela')}
            for role, record in retained.items():
                (directory/f'{role}.pid').write_text(str(record['pid']))
            manifest = dict(directory=str(directory), binary=str(binary), processes=retained)
            (directory/'processes.json').write_text(json.dumps(manifest))
            (directory/'ready').touch()
            for bad in [identity(111, 'server', instance=Path(str(directory)+'-different')),
                        identity(111, 'server', start='reused'),
                        identity(111, 'rela'),
                        dict(retained['server'], argv=['/usr/bin/sleep', '100'])]:
                with self.subTest(bad=bad), patch.object(launch, 'process_identity', side_effect=lambda pid: bad if pid == 111 else retained['rela']), patch.object(launch.os, 'kill') as kill:
                    with self.assertRaises(ValueError):
                        launch.stop_instance(directory)
                    kill.assert_not_called()
                    self.assertTrue((directory/'ready').exists())
            # The second role is preflighted too: no partial stop of the valid server.
            for bad in [identity(222, 'rela', instance=Path(str(directory)+'-different')),
                        identity(222, 'rela', start='reused'), identity(222, 'server')]:
                with self.subTest(rela=bad), patch.object(launch, 'process_identity', side_effect=lambda pid: retained['server'] if pid == 111 else bad), patch.object(launch.os, 'kill') as kill:
                    with self.assertRaises(ValueError): launch.stop_instance(directory)
                    kill.assert_not_called()
            (directory/'server.pid').write_text('333')
            with patch.object(launch, 'process_identity', side_effect=lambda pid: retained['server'] if pid == 111 else retained['rela']), patch.object(launch.os, 'kill') as kill:
                with self.assertRaises(ValueError): launch.stop_instance(directory)
                kill.assert_not_called()
            (directory/'server.pid').write_text('111')
            # Do not trust a manifest which itself describes a sibling prefix or role swap.
            for bad in [identity(111, 'server', instance=Path(str(directory)+'-different')), identity(111, 'rela')]:
                changed = dict(retained, server=bad)
                (directory/'processes.json').write_text(json.dumps(dict(manifest, processes=changed)))
                with patch.object(launch, 'process_identity', side_effect=lambda pid: changed['server'] if pid == 111 else changed['rela']), patch.object(launch.os, 'kill') as kill:
                    with self.assertRaises(ValueError): launch.stop_instance(directory)
                    kill.assert_not_called()
            (directory/'processes.json').write_text(json.dumps(manifest))
            with patch.object(launch, 'process_identity', side_effect=lambda pid: retained['server'] if pid == 111 else retained['rela']), patch.object(launch.os, 'kill') as kill:
                launch.stop_instance(directory)
                self.assertEqual([call.args[0] for call in kill.call_args_list], [111, 222])
                self.assertFalse((directory/'ready').exists())

    def test_no_metadata_refuses_instead_of_guessing_from_pid_or_command(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(launch.os, 'kill') as kill:
                with self.assertRaises(ValueError): launch.stop_instance(Path(temporary))
                kill.assert_not_called()


if __name__ == '__main__': unittest.main()
