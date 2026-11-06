#!/usr/bin/env python3
"""Private file-backed Fly peer. Never opens network or invokes shell commands."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import tarfile

sys.path.insert(0, os.environ['FAKE_BACKUP_MODULE'])
import backup

args = sys.argv[1:]
root = Path(os.environ['FAKE_BACKUP_ROOT'])
app = args[args.index('-a') + 1]
assert app in backup.APPS
name = backup.APPS[app]
assert os.environ['FLY_API_TOKEN'] == 'synthetic-' + name
with (root / 'calls.jsonl').open('a') as log:
    log.write(json.dumps(args) + '\n')
base = root / app

def local(path):
    assert path.startswith(('/data/', '/tmp/', '/app/')) and '..' not in Path(path).parts
    return base / path.lstrip('/')

def fail():
    print('PRIVATE_ERROR_DO_NOT_PUBLISH', file=sys.stderr)
    sys.exit(1)

pattern = os.environ.get('FAKE_BACKUP_FAIL')
if pattern and pattern in ' '.join(args):
    fail()

scenario = os.environ.get('FAKE_BACKUP_REPLACE_AT')
holds = [(root/a/'data/hold').exists() for a in backup.APPS]
replace = (scenario == 'hold' and any(holds)) or (scenario == 'copy' and all(holds)) or (scenario == 'release' and (root/'ready-release').exists())
if os.environ.get('FAKE_BACKUP_REPLACE_IMAGE') and replace:
    changed_image = True
else:
    changed_image = False
trigger = os.environ.get('FAKE_BACKUP_PENDING_AT')
if (trigger == 'hold' and any(holds)) or (trigger == 'copy' and all(holds)) or (trigger == 'release' and (root/'ready-release').exists()):
    pending = local('/data/incoming/'+name+'.tar.gz');pending.parent.mkdir(exist_ok=True)
    if not pending.exists():
        with tarfile.open(pending, 'w:gz') as archive:
            archive.add(local('/data/'+name), arcname='.')
if os.environ.get('FAKE_BACKUP_FOREIGN_HOLD') and (root/'ready-release').exists():
    local('/data/hold').write_text('foreign-operation')
machine_id = app + ('-replacement' if replace and not os.environ.get('FAKE_BACKUP_REPLACE_IMAGE') else '-machine')
if args[0] == 'status':
    hold = local('/data/hold').exists()
    print(json.dumps({'Machines': [{'id': machine_id, 'state': 'started',
        'checks': [{'status': 'critical' if hold else 'passing'}],
        'image_ref': {'tag': 'master-' + backup.MASTER, 'digest': 'wrong' if os.environ.get('FAKE_BACKUP_WRONG_IMAGE') or changed_image else backup.IMAGES[app]}}]}))
elif args[:2] == ['machine', 'restart']:
    assert args[2] in [app + '-machine', app + '-replacement']
    pending = local('/data/incoming/' + name + '.tar.gz')
    if pending.exists():
        local('/data/' + name).rename(local('/data/displaced-' + name))
        local('/data/' + name).mkdir()
        with tarfile.open(pending) as archive:
            archive.extractall(local('/data/' + name), filter='data')
        pending.unlink()
        local('/data/hold').unlink(missing_ok=True)
elif args[:2] == ['ssh', 'console']:
    if '--machine' in args:
        assert args[args.index('--machine')+1] == machine_id
    command = args[args.index('-C') + 1]
    words = shlex.split(command)
    if command.startswith('python3 -c') and len(words) == 4:
        payload = json.loads(words[3])
        # Execute the actual remote guard, with only absolute paths mapped to
        # this private fixture and the final command dispatched below, not a shell.
        import subprocess
        code = words[2].replace("'/data/", "'"+str(base)+"/data/")
        code = code.replace("subprocess.run(p['command'],shell=True,check=True)", 'None')
        result = subprocess.run([sys.executable, '-c', code, words[3]], capture_output=True)
        if result.returncode: fail()
        if payload['action'] != 'run': sys.exit(0)
        command = payload['command'];words = shlex.split(command)
    if command.startswith('python3 -c'):
        pass
    elif command.startswith('env ATLAS_RELA_DATA='):
        pass
    elif words[:1] == ['test']:
        exists = local(words[-1]).exists()
        if (not exists) if '!' not in words else exists:
            fail()
    elif words[0] == 'touch':
        local(words[1]).touch()
    elif words[0] == 'rm':
        local(words[-1]).unlink(missing_ok=True)
        if words[-1] == '/tmp/beam.tar.gz': (root/'ready-release').touch()
    elif words[0] == 'tar':
        archive = local(words[2]); archive.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive, 'w:gz') as file:
            for path in sorted(local(words[4]).iterdir()):
                file.add(path, arcname=path.name)
    elif words[0] == '/app/fly/manifest.sh':
        print(backup.manifest(local(words[1])), end='')
    elif words[0] == '/app/fly/counts.sh':
        print('issues 1\nlinks 0')
    elif words[0] == 'sha256sum':
        path = words[1]
        if path == '/app/rela/atlas.manifest.json':
            sha = os.environ['FAKE_BACKUP_MANIFEST']
        else:
            sha = backup.digest(local(path))
        print(sha + '  ' + path)
    elif words[0] == 'cat':
        print(local(words[1]).read_text(), end='')
    elif words[0] == 'mkdir':
        local(words[-1]).mkdir(parents=True, exist_ok=True)
    elif words[0] == 'mv':
        local(words[1]).rename(local(words[2]))
    else:
        raise AssertionError(command)
elif args[:2] == ['ssh', 'sftp']:
    if '--machine' in args:
        at = args.index('--machine')
        assert args[at+1] == machine_id
        args = args[:at]+args[at+2:]
    _, _, op, _, _, source, target = args
    if op == 'get':
        shutil.copyfile(local(source), target)
        (root/'copied').touch()
        if os.environ.get('FAKE_BACKUP_CORRUPT'):
            with open(target, 'ab') as file:
                file.write(b'changed transport')
    elif op == 'put':
        shutil.copyfile(source, local(target))
    else:
        raise AssertionError(op)
else:
    raise AssertionError(args)
