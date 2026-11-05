#!/usr/bin/env python3
"""Private IS125 prototype launcher. No live environment settings are read."""
import os
import ctypes
import json
from pathlib import Path
import signal
import subprocess
import sys
import struct
import time

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'tools/runtime-playground/playground.exs'
ENV = dict(os.environ, MIX_ENV='test', ELIXIR_ERL_OPTIONS='+S 1:1')
# Private configuration only. No inherited model, Bus link or live environment file.
for key in list(ENV):
    if key.startswith('ATLAS_'):
        del ENV[key]


def beam(*args, no_start=False):
    if no_start:
        paths = [arg for path in (ROOT/'beam/_build/test/lib').glob('*/ebin') for arg in ('-pa', str(path))]
        return ['elixir', *paths, str(SCRIPT), *map(str, args)]
    return ['mix', 'run', '--no-compile', '--no-deps-check', *(['--no-start'] if no_start else []), str(SCRIPT), *map(str, args)]


def process_identity(pid):
    """Read OS argv boundaries and process birth identity; never parse ps prose."""
    if pid <= 1:
        raise ValueError('invalid retained PID')
    if sys.platform == 'linux':
        proc = Path('/proc')/str(pid)
        def birth():
            # stat's parenthesized comm can contain spaces and parentheses.
            return (proc/'stat').read_text().rsplit(')', 1)[1].split()[19]
        start = birth()
        argv = [os.fsdecode(arg) for arg in (proc/'cmdline').read_bytes().rstrip(b'\0').split(b'\0')]
        result = dict(pid=pid, start=[Path('/proc/sys/kernel/random/boot_id').read_text().strip(), start], uid=proc.stat().st_uid, exe=str((proc/'exe').resolve(strict=True)), argv=argv)
        if birth() != start:
            raise ValueError('process changed during inspection')
        return result
    if sys.platform != 'darwin':
        raise ValueError('process identity inspection unsupported on this OS')
    libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    libc = ctypes.CDLL(None, use_errno=True)
    def birth():
        # SDK sys/proc_info.h: PROC_PIDTBSDINFO=3, proc_bsdinfo size 136.
        data = ctypes.create_string_buffer(136)
        if libproc.proc_pidinfo(pid, 3, 0, data, 136) != 136:
            raise ValueError('retained process unavailable')
        return list(struct.unpack_from('=QQ', data.raw, 120)), struct.unpack_from('=I', data.raw, 20)[0]
    start, uid = birth()
    # SDK sys/sysctl.h: CTL_KERN=1, KERN_PROCARGS2=49; argc + exec path + argv.
    data = ctypes.create_string_buffer(1_048_576)
    size = ctypes.c_size_t(len(data))
    mib = (ctypes.c_int * 3)(1, 49, pid)
    if libc.sysctl(mib, 3, data, ctypes.byref(size), None, 0) != 0:
        raise ValueError('retained process arguments unavailable')
    raw = data.raw[:size.value]
    argc = struct.unpack_from('=i', raw)[0]
    offset = raw.index(b'\0', 4) + 1
    while offset < len(raw) and raw[offset] == 0:
        offset += 1
    argv = []
    for _ in range(argc):
        end = raw.index(b'\0', offset)
        argv.append(os.fsdecode(raw[offset:end]))
        offset = end + 1
    executable = ctypes.create_string_buffer(4096)
    if libproc.proc_pidpath(pid, executable, len(executable)) <= 0 or birth() != (start, uid):
        raise ValueError('retained process changed or unavailable')
    return dict(pid=pid, start=start, uid=uid, exe=str(Path(os.fsdecode(executable.value)).resolve()), argv=argv)


def check_role(record, role, directory, binary):
    argv = record['argv']
    if record['uid'] != os.getuid():
        raise ValueError('retained process belongs to another user')
    if role == 'server':
        valid = Path(record['exe']).name == 'beam.smp' and argv[-4:] == [str(SCRIPT), 'server', str(directory), str(binary)]
    else:
        valid = (record['exe'] == str(binary) and len(argv) == 8 and
                 argv[:5] == [str(binary), '-project', str(directory/'rela'), '-bind', '127.0.0.1'] and
                 argv[5] == '-port' and argv[6].isdigit() and argv[7] == '-quiet')
    if not valid:
        raise ValueError(f'{role} PID does not identify this exact private instance and role')


def retain_processes(directory, binary):
    records = {}
    for role in ('server', 'rela'):
        records[role] = process_identity(int((directory/f'{role}.pid').read_text()))
        check_role(records[role], role, directory, binary)
    (directory/'processes.json').write_text(json.dumps(dict(directory=str(directory), binary=str(binary), processes=records)))


def stop_instance(directory):
    directory = directory.resolve()
    try:
        manifest = json.loads((directory/'processes.json').read_text())
        if manifest['directory'] != str(directory):
            raise ValueError('retained instance directory mismatch')
        binary = Path(manifest['binary']).resolve()
        records = manifest['processes']
        # Check both roles before sending any signal, then recheck immediately per PID.
        for role in ('server', 'rela'):
            record = records[role]
            check_role(record, role, directory, binary)
            if int((directory/f'{role}.pid').read_text()) != record['pid'] or process_identity(record['pid']) != record:
                raise ValueError(f'{role} retained PID is stale or reused')
        for role in ('server', 'rela'):
            record = records[role]
            if process_identity(record['pid']) != record:
                raise ValueError(f'{role} process identity changed before stop')
            os.kill(record['pid'], signal.SIGTERM)
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        raise ValueError('cannot prove retained process ownership; refusing stop') from error
    (directory/'ready').unlink(missing_ok=True)


def main():
    args = sys.argv[1:]
    if len(args) < 3 or args[0] not in ('playground', 'attach'):
        raise ValueError('prototype: atlas playground init|stop|probe DIR [COMMAND ...]; atlas attach WORKER --prototype DIR')
    if args[0] == 'attach':
        if len(args) != 4 or args[2] != '--prototype':
            raise ValueError('prototype: atlas attach breaker --prototype DIR')
        return subprocess.call(beam('attach', Path(args[3]).resolve(), args[1], no_start=True), cwd=ROOT/'beam', env=ENV)
    action, directory, *words = args[1:]
    directory = Path(directory).expanduser().resolve()
    if action == 'init':
        if directory.exists() or len(str(directory)) > 75:
            raise ValueError('choose a fresh private directory with a path of at most 75 characters')
        cache = Path(os.environ.get('ATLAS_E2E_RELA_BIN', str(Path.home()/'.local/share/atlas/test/bin')))
        binary = (cache/'rela-server').resolve()
        if not binary.is_file():
            raise ValueError('cached rela-server required; this prototype never downloads dependencies')
        directory.mkdir(mode=0o700, parents=True)
        python = os.environ.get('ATLAS_CONFIG_PYTHON', '/usr/bin/python3')
        subprocess.run([python, str(ROOT/'rela/scripts/config.py'), 'copy', '--root', str(ROOT/'rela'), '--data', str(directory/'rela')], check=True)
        subprocess.run(['mix', 'compile', '--warnings-as-errors'], cwd=ROOT/'beam', env=ENV, check=True)
        with (directory/'server.log').open('wb') as log:
            child = subprocess.Popen(beam('server', directory, binary), cwd=ROOT/'beam', env=ENV, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        (directory/'server.pid').write_text(str(child.pid))
        for _ in range(100):
            if (directory/'ready').exists():
                retain_processes(directory, binary)
                print(f'PRIVATE STUB ready: {directory}\nAttach: {ROOT}/bin/atlas attach breaker --prototype {directory}\nStop instance: {ROOT}/bin/atlas playground stop {directory}')
                return 0
            if child.poll() is not None:
                raise ValueError((directory/'server.log').read_text()[-5000:])
            time.sleep(.1)
        raise ValueError(f'private startup timed out; inspect {directory}/server.log and stop this instance')
    if not (directory/'server.pid').exists():
        raise ValueError('not a ready private playground directory')
    if action == 'stop':
        stop_instance(directory)
        print(f'Private instance stopped; evidence preserved at {directory}')
        return 0
    if action == 'probe' and words:
        return subprocess.call(beam('probe', directory, 'breaker', *words, no_start=True), cwd=ROOT/'beam', env=ENV)
    raise ValueError('supported actions: init, stop, probe')


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f'playground: {error}')
