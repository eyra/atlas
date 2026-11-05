"""Private readonly regressions; no Runtime, proxy or model is started."""
import json
import importlib.util
from unittest.mock import patch
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RuntimeStatusTest(unittest.TestCase):
    def call(self, directory, pid=None):
        client = directory/'client.json'; client.write_text(json.dumps({'env': 'test', 'control': {'port': 1}}))
        home = directory/'runtime'
        if pid is not None:
            home.mkdir()
            (home/'runtime.pid').write_text(str(pid))
            (home/'runtime.json').write_text(json.dumps({'env': 'test', 'runtime': {'machine': 'fixture'}, 'bus_link': {'machine': 'fixture'}}))
        result = subprocess.run([sys.executable, str(ROOT/'tools/runtime.py'), 'runtime-status', str(ROOT), str(client), 'test'],
            text=True, capture_output=True, env=dict(os.environ, ATLAS_RUNTIME_HOME=str(home), ATLAS_RUNTIME_FILE=str(home/'runtime.json'), ELIXIR_ERL_OPTIONS='+S 1:1'))
        return result, home

    def test_status_does_not_create_runtime_home(self):
        with tempfile.TemporaryDirectory() as directory:
            result, home = self.call(Path(directory))
            self.assertFalse(home.exists(), result.stdout+result.stderr)

    def test_retained_live_pid_is_not_runtime_health_or_ownership(self):
        with tempfile.TemporaryDirectory() as directory:
            result, _ = self.call(Path(directory), os.getpid())
            self.assertNotIn('running (pid', result.stdout)
            self.assertIn('unverified', result.stdout.lower(), result.stdout+result.stderr)


class StatusProjectionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('runtime_status_subject', ROOT/'tools/runtime.py')
        cls.subject = importlib.util.module_from_spec(spec)
        previous = sys.dont_write_bytecode
        try:
            sys.dont_write_bytecode = True
            spec.loader.exec_module(cls.subject)
        finally:
            sys.dont_write_bytecode = previous

    def test_synthetic_statuses_have_no_mutation_or_signal_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            config = home/'runtime.json'
            config.write_text(json.dumps({'env': 'test', 'runtime': {'machine': 'fixture'}, 'bus_link': {'machine': 'fixture', 'token': 'NEVER-PRINT-THIS'}}))
            target = dict(environment='test', machine='fixture')
            with patch.dict(os.environ, ATLAS_RUNTIME_HOME=str(home), ATLAS_RUNTIME_FILE=str(config)):
                def observe(**kwargs): return self.subject.observe_status(ROOT, 'test', {'target': target}, **kwargs)
                self.assertEqual(observe()['state'], 'absent')
                (home/'runtime.pid').write_text('1234')
                before = {str(p): (p.read_bytes(), p.stat().st_mtime_ns) for p in home.iterdir()}
                with patch.object(self.subject.os, 'kill', side_effect=AssertionError('signal forbidden')), patch.object(self.subject.os, 'killpg', side_effect=AssertionError('group signal forbidden')), patch.object(self.subject.subprocess, 'Popen', side_effect=AssertionError('startup forbidden')), patch.object(Path, 'mkdir', side_effect=AssertionError('mkdir forbidden')):
                    status = observe(inspect_process=lambda pid: {'uid': os.getuid(), 'exe': '/unrelated/python', 'start': 'reused'})
                    self.assertEqual(status['state'], 'unverified')
                    self.assertTrue(status['process_present'])
                    self.assertEqual(status['pid'], 1234)
                    self.assertEqual(status['capabilities'], dict(local_status=True, local_start=False, local_stop=False, remote_status=False))
                    def missing(pid): raise OSError('missing')
                    self.assertEqual(observe(inspect_process=missing)['state'], 'stale')
                    self.assertEqual(observe(inspect_process=lambda pid: {'uid': -1})['basis'], 'owner_mismatch')
                    for target in [dict(environment='prod', machine='fixture'), dict(environment='test', machine='other')]:
                        self.assertEqual(observe()['state'], 'unsupported')
                self.assertEqual(before, {str(p): (p.read_bytes(), p.stat().st_mtime_ns) for p in home.iterdir()})
                self.assertNotIn('NEVER-PRINT-THIS', json.dumps(status))

    def test_cli_alias_json_and_missing_or_stale_private_records(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)/'absent'
            client = Path(temporary)/'client.json'; client.write_text(json.dumps({'env': 'test', 'control': {'port': 1}}))
            env = dict(os.environ, ATLAS_ENV_FILE=str(client), ATLAS_RUNTIME_HOME=str(home), ATLAS_RUNTIME_FILE=str(home/'runtime.json'), PYTHONDONTWRITEBYTECODE='1')
            def call(words):
                return subprocess.run([str(ROOT/'bin/atlas'), *words, '--env', 'test', '--machine', 'fixture', '--json'], env=env, text=True, capture_output=True)
            for words in [['runtime', 'status'], ['runtime-status']]:
                result = call(words)
                self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
                frame = json.loads(result.stdout)
                self.assertEqual(frame['target'], dict(environment='test', machine='fixture'))
                self.assertEqual(frame['status']['state'], 'absent')
                self.assertFalse(home.exists())
            home.mkdir(); (home/'runtime.json').write_text(json.dumps({'env': 'test', 'runtime': {'machine': 'fixture'}, 'bus_link': {'machine': 'fixture'}}))
            (home/'runtime.pid').write_text('not-a-pid')
            self.assertEqual(json.loads(call(['runtime', 'status']).stdout)['status']['state'], 'stale')
            for words in [['runtime', 'status', '--unknown'], ['runtime', 'status', '--machine', 'other']]:
                result = call(words)
                self.assertNotEqual(result.returncode, 0)
            result = call(['runtime', 'stop'])
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('unsupported', result.stderr)


    def test_status_never_builds_or_writes_import_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)/'runtime'; home.mkdir()
            config = home/'runtime.json'; config.write_text(json.dumps({'env': 'test', 'runtime': {'machine': 'fixture'}, 'bus_link': {'machine': 'fixture'}}))
            (home/'runtime.pid').write_text('1234')
            fake = Path(temporary)/'checkout'; (fake/'tools/runtime-playground').mkdir(parents=True)
            (fake/'tools/runtime-playground/launch.py').write_text('def process_identity(pid): return {"uid": '+str(os.getuid())+'}\n')
            before = sorted(str(p) for p in Path(temporary).rglob('*'))
            previous = sys.dont_write_bytecode
            try:
                sys.dont_write_bytecode = False
                with patch.dict(os.environ, ATLAS_RUNTIME_HOME=str(home), ATLAS_RUNTIME_FILE=str(config)):
                    self.assertEqual(self.subject.observe_status(fake, 'test', {'target': dict(environment='test', machine='fixture')})['state'], 'unverified')
                    with patch.object(self.subject.subprocess, 'call', side_effect=AssertionError('build/start forbidden')):
                        self.assertEqual(self.subject.status_cli(fake, 'test', []), 2)
            finally:
                sys.dont_write_bytecode = previous
            self.assertEqual(before, sorted(str(p) for p in Path(temporary).rglob('*')))

    def test_generated_adapter_refuses_malformed_or_foreign_helper_projection(self):
        with tempfile.TemporaryDirectory() as temporary:
            fake = Path(temporary); (fake/'tools').mkdir()
            model = dict(target=dict(environment='test', machine='foreign'), state='absent', basis='fixture', message='fixture', capabilities=dict(local_status=True, local_start=False, local_stop=False, remote_status=False))
            paths = [arg for p in (ROOT/'bff/contract/_build/test/lib').glob('*/ebin') for arg in ('-pa', str(p))]
            for target in [dict(environment='test', machine='foreign'), ['not-an-object']]:
                model['target'] = target
                (fake/'tools/runtime.py').write_text('print('+repr(json.dumps(model))+')')
                result = subprocess.run(['elixir', *paths, str(ROOT/'tools/runtime_status.exs'), str(fake), 'test', str(fake/'missing.json'), '--machine', 'fixture', '--json'], env=dict(os.environ, ELIXIR_ERL_OPTIONS='+S 1:1'), text=True, capture_output=True)
                self.assertEqual(result.returncode, 2, result.stdout+result.stderr)
                self.assertEqual(json.loads(result.stdout)['error']['code'], 'invalid_diagnostic')


if __name__ == '__main__': unittest.main()
