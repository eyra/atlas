"""Bounded integration proof: real private State/Flow/Runtime, built-in stub only."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
ATLAS = str(ROOT/'bin/atlas')


class PlaygroundTest(unittest.TestCase):
    def test_viewer_lifecycle_and_existing_recovery(self):
        # Short path for macOS Unix sockets; launcher requires a fresh directory.
        with tempfile.TemporaryDirectory(prefix='atlas-pg-', dir='/tmp') as parent:
            directory = os.environ.get('ATLAS_PRIVATE_PROOF_DIR', str(Path(parent)/'private'))
            started = subprocess.run([ATLAS, 'playground', 'init', directory], capture_output=True, text=True)
            self.assertEqual(started.returncode, 0, started.stdout+started.stderr)
            target = dict(environment='private', machine='runtime-playground', worker='breaker')
            counter = 0

            def connect():
                connection = socket.socket(socket.AF_UNIX)
                connection.settimeout(15)
                connection.connect(directory+'/runtime.sock')
                return connection, connection.makefile('rb')

            connection, reader = connect()

            def request(op, **extra):
                nonlocal counter
                counter += 1
                frame = dict(op=op, channel='control', version='0.1.0', id=str(counter), target=target, **extra)
                connection.sendall(json.dumps(frame).encode()+b'\n')
                while True:
                    reply = json.loads(reader.readline())
                    if reply.get('channel') == 'control':
                        self.assertEqual(reply['id'], str(counter))
                        return reply

            def status():
                return request('status')['status']

            def eventually(predicate, seconds=15):
                deadline = time.monotonic()+seconds
                while time.monotonic() < deadline:
                    current = status()
                    if predicate(current):
                        return current
                    time.sleep(.3)
                self.fail('private Runtime did not reach expected state')

            def running(current):
                return [t for t in current['turns'] if t['state'] == 'running']

            try:
                self.assertEqual(os.stat(directory).st_mode & 0o777, 0o700)
                self.assertEqual(os.stat(directory+'/runtime.sock').st_mode & 0o777, 0o600)
                self.assertFalse(request('attach')['status']['engine_running'])
                self.assertEqual(status()['turns'], [])
                request('start')
                first = eventually(lambda s: len(running(s)) == 1)
                turn = running(first)[0]['execution']['turn']
                execution = running(first)[0]['execution']
                self.assertTrue(execution['attempt'])
                viewers = [connect(), connect()]
                def scoped(viewer, op, selected=execution):
                    sock, stream = viewer
                    frame = dict(op='execution_'+op, channel='control', version='0.1.0',
                                 id='private-'+op, target=target, execution=selected)
                    sock.sendall(json.dumps(frame).encode()+b'\n')
                    while True:
                        reply = json.loads(stream.readline())
                        if reply.get('channel') == 'control':
                            self.assertEqual(reply['id'], frame['id'])
                            return reply
                def snapshot(viewer):
                    while True:
                        event = json.loads(viewer[1].readline())
                        if event.get('channel') == 'event': return event
                for viewer in viewers:
                    attached = scoped(viewer, 'attach')
                    self.assertEqual(attached['execution'], execution)
                    self.assertEqual(attached['turn']['execution'], execution)
                    self.assertEqual(attached['capabilities'], dict(snapshot=True, control=False, guidance=False, output=False, replay=False))
                self.assertEqual([t['execution'] for t in running(status())], [execution])
                scoped(viewers[0], 'detach')
                viewers[0][1].close(); viewers[0][0].close()
                self.assertEqual(snapshot(viewers[1])['execution'], execution)
                viewers[0] = connect()
                self.assertEqual(scoped(viewers[0], 'attach')['execution'], execution)
                stale = dict(execution, attempt='not-current')
                other = connect()
                try:
                    self.assertEqual(scoped(other, 'attach', stale)['error']['code'], 'stale_execution')
                    unfenced = dict(execution); unfenced.pop('attempt')
                    self.assertEqual(scoped(other, 'attach', unfenced)['error']['code'], 'exact_execution_required')
                finally:
                    other[1].close(); other[0].close()
                request('start')  # idempotent; no second engine or worker
                request('detach')
                reader.close(); connection.close()
                connection, reader = connect()
                current = request('attach')['status']
                self.assertEqual([t['execution']['turn'] for t in running(current)], [turn])
                request('stub_mode', mode='idle')
                eventually(lambda s: running(s)[0].get('activity') == 'idle')
                request('stub_mode', mode='crash once')
                recovered = eventually(lambda s: len(s['turns']) == 2 and len(running(s)) == 1)
                self.assertIn('crashed', recovered['turns'][0]['reason'])
                for viewer in viewers:
                    event = snapshot(viewer)
                    while event['op'] != 'execution_closed':
                        self.assertEqual(event['execution'], execution)
                        self.assertEqual(event['turn']['execution'], execution)
                        event = snapshot(viewer)
                    self.assertEqual(event['execution'], execution)
                    self.assertEqual(event['error']['code'], 'stale_execution')
                    self.assertEqual(scoped(viewer, 'attach')['error']['code'], 'stale_execution')
                    viewer[1].close(); viewer[0].close()
                print('PASS: two exact-execution viewers, fenced status, readonly capabilities, independent detach/reconnect, stale closure without successor')
                request('stub_mode', mode='silent')
                recovered = eventually(lambda s: any('silent for 8 s' in t.get('reason', '') for t in s['turns']), 14)
                request('stub_mode', mode='active')
                request('stop')
                eventually(lambda s: not s['engine_running'] and not running(s))
                # A wrong exact identity is a typed refusal, never an implicit worker creation.
                target['worker'] = 'unknown'
                error = request('start')
                self.assertEqual(error['error']['code'], 'wrong_target')
                target['worker'] = 'breaker'
                self.assertFalse(status()['engine_running'])
                self.assertNotIn('harness', status()['capabilities'])
                print('PASS: attach/detach/reconnect identity, explicit stop, crash/silence recovery, typed wrong-target refusal')
            finally:
                reader.close(); connection.close()
                subprocess.run([ATLAS, 'playground', 'stop', directory], check=True, capture_output=True)


if __name__ == '__main__':
    unittest.main()
