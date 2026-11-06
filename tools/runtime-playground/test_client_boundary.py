"""Actual terminal/probe Client + Unix peer fixture; no Runtime or agent starts."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
TARGET = dict(environment='private', machine='runtime-playground', worker='breaker')


def status(item):
    return dict(target=TARGET, engine_running=False,
                capabilities=dict(controls=dict(status=True, start=True, stop=True, stub_mode=True)),
                turns=[], item=item)


class ClientTest(unittest.TestCase):
    @contextmanager
    def peer(self, mode='attach', exact=False):
        with tempfile.TemporaryDirectory(prefix='atlas-client-', dir='/tmp') as temporary:
            directory = Path(temporary)
            listener = socket.socket(socket.AF_UNIX)
            listener.bind(str(directory/'runtime.sock')); listener.listen(); listener.settimeout(5)
            runner = directory/'runner.exs'
            runner.write_text('''Code.require_file(Path.expand("../../clients/agent/lib/atlas_agent/runtime_session.ex", Path.dirname(hd(System.argv()))))
source = File.read!(hd(System.argv()))
[_, client] = String.split(source, "defmodule RuntimePlayground.Client do", parts: 2)
[client, _] = String.split(client, "\\ncase System.argv() do", parts: 2)
Code.compile_string("defmodule RuntimePlayground.Client do" <> client)
RuntimePlayground.Client.run(Enum.at(System.argv(), 1), Enum.at(System.argv(), 2), "breaker", ["status"])
''')
            command = ['elixir']
            for path in (ROOT/'beam/_build/test/lib').glob('*/ebin'):
                command += ['-pa', str(path)]
            command += [str(runner), str(ROOT/'tools/runtime-playground/playground.exs'), mode, temporary]
            if exact:
                command = [str(ROOT/'bin/atlas'), 'attach', 'breaker', '--prototype', temporary,
                           '--attempt', 'a1', '--turn', 't1']
            child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     env=dict(os.environ, ELIXIR_ERL_OPTIONS='+S 1:1'))
            connection = None
            output = b''
            try:
                connection, _ = listener.accept(); connection.settimeout(3)
                reader = connection.makefile('rb', buffering=0)
                def receive(): return json.loads(reader.readline())
                def send(frame): connection.sendall(json.dumps(frame).encode()+b'\n')
                def wait(marker, seconds=3):
                    nonlocal output
                    deadline = time.monotonic()+seconds
                    while marker.encode() not in output and time.monotonic() < deadline:
                        if select.select([child.stdout], [], [], max(deadline-time.monotonic(), 0))[0]:
                            data = os.read(child.stdout.fileno(), 65536)
                            if not data: break
                            output += data
                    self.assertIn(marker.encode(), output, output.decode(errors='replace'))
                def absent(marker):
                    if select.select([child.stdout], [], [], .15)[0]:
                        output_data = os.read(child.stdout.fileno(), 65536)
                        # Pull newly emitted lines without requiring a positive marker.
                        nonlocal_output(output_data)
                    self.assertNotIn(marker.encode(), output)
                def nonlocal_output(data):
                    nonlocal output
                    output += data
                yield child, receive, send, wait, absent
            finally:
                if child.poll() is None:
                    child.stdin.write(b'detach\n'); child.stdin.flush()
                    try: child.wait(timeout=3)
                    except subprocess.TimeoutExpired: child.terminate(); child.wait(timeout=3)
                if connection:
                    reader.close(); connection.close()
                listener.close(); child.stdin.close(); child.stdout.close()

    def result(self, request, item):
        return dict(op='result', channel='control', version='0.1.0', id=request['id'], target=TARGET, status=status(item))

    def test_large_status_reply_and_event_remain_single_json_lines(self):
        # The retained human demo grew past the OS line buffer (9,216 bytes).
        # Exercise the real socket client, not only the JSON/session decoder.
        item = 'x' * 120_000
        with self.peer() as (child, receive, send, wait, absent):
            send(self.result(receive(), item))
            wait('item=' + item)
            send(dict(op='status', channel='event', version='0.1.0', sequence=1,
                      target=TARGET, status=status('AFTER-LARGE-' + item)))
            wait('item=AFTER-LARGE-' + item)
            child.stdin.write(b'status\n'); child.stdin.flush()
            send(self.result(receive(), 'STILL-CORRELATED'))
            wait('item=STILL-CORRELATED')
            absent('INVALID')

    def test_exact_cli_rejects_lifecycle_and_foreign_events_then_closes_only_subscription(self):
        execution = dict(worker=TARGET, turn='t1', attempt='a1')
        turn = dict(execution=execution, item='fixture', state='running')
        capabilities = dict(snapshot=True, control=False, guidance=False, output=False, replay=False)
        with self.peer(exact=True) as (child, receive, send, wait, absent):
            request = receive()
            self.assertEqual(request['op'], 'execution_attach')
            self.assertEqual(request['execution'], execution)
            send(dict(op='execution_result', channel='control', version='0.1.0', id=request['id'],
                      target=TARGET, execution=execution, turn=turn, capabilities=capabilities))
            wait('execution=t1/a1')
            child.stdin.write(b'stop\n'); child.stdin.flush()
            wait('Command not sent:')
            event = dict(op='execution_snapshot', channel='event', version='0.1.0', sequence=1,
                         target=TARGET, execution=dict(execution, attempt='successor'), turn=turn, capabilities=capabilities)
            send(event); wait('INVALID event target mismatch')
            send(dict(op='execution_closed', channel='event', version='0.1.0', sequence=2,
                      target=TARGET, execution=execution,
                      error=dict(code='stale_execution', message='ended', retryable=False)))
            wait('Subscription closed: stale_execution; no successor selected.')
            self.assertEqual(child.wait(timeout=3), 0)

    def test_probe_refuses_foreign_outer_status_execution_and_error_targets(self):
        for location in ('outer', 'status', 'execution', 'error'):
            with self.subTest(location=location), self.peer('probe') as (child, receive, send, wait, absent):
                request = receive()
                foreign = dict(TARGET, machine='foreign')
                frame = self.result(request, 'FOREIGN-PROBE')
                if location == 'outer': frame['target'] = foreign
                if location == 'status': frame['status']['target'] = foreign
                if location == 'execution':
                    frame['status']['turns'] = [dict(execution=dict(worker=foreign, turn='t'), item='item', state='running')]
                if location == 'error':
                    frame = dict(op='error', channel='control', version='0.1.0', id=request['id'], target=foreign,
                                 error=dict(code='foreign', message='FOREIGN-PROBE', retryable=False))
                send(frame); wait('invalid control response: reply target mismatch')
                absent('FOREIGN-PROBE')
                self.assertNotEqual(child.wait(timeout=3), 0)

    def test_terminal_error_completion_is_consumed_and_replay_rejected(self):
        with self.peer() as (child, receive, send, wait, absent):
            request = receive()
            error = dict(op='error', channel='control', version='0.1.0', id=request['id'],
                         error=dict(code='refused', message='FIRST-ERROR', retryable=False))
            send(error); wait('FIRST-ERROR')
            error['error']['message'] = 'REPLAYED-ERROR'
            send(error); wait('duplicate or unknown reply'); absent('REPLAYED-ERROR')
            child.stdin.write(b'status\n'); child.stdin.flush()
            send(self.result(receive(), 'AFTER-ERROR')); wait('item=AFTER-ERROR')

    def test_terminal_backpressure_expiry_late_reply_and_events_stay_separate(self):
        with self.peer() as (child, receive, send, wait, absent):
            send(self.result(receive(), 'INITIAL')); wait('item=INITIAL')
            child.stdin.write(b'status\n'*9); child.stdin.flush()
            requests = [receive() for _ in range(8)]
            wait('BACKPRESSURE: 8 requests outstanding')
            send(dict(op='status', channel='event', version='0.1.0', sequence=1, target=TARGET, status=status('EVENT')))
            wait('item=EVENT')
            wait('EXPIRED request', 11)
            send(self.result(requests[0], 'LATE-COMPLETE')); wait('duplicate or unknown reply'); absent('LATE-COMPLETE')
            child.stdin.write(b'status\n'); child.stdin.flush()
            send(self.result(receive(), 'AFTER-EXPIRY')); wait('item=AFTER-EXPIRY')


if __name__ == '__main__': unittest.main()
