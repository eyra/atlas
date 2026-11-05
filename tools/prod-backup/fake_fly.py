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

if args[0] == 'status':
    hold = local('/data/hold').exists()
    print(json.dumps({'Machines': [{'id': app + '-machine', 'state': 'started',
        'checks': [{'status': 'critical' if hold else 'passing'}],
        'image_ref': {'tag': 'master-' + backup.MASTER, 'digest': 'wrong' if os.environ.get('FAKE_BACKUP_WRONG_IMAGE') else backup.IMAGES[app]}}]}))
elif args[:2] == ['machine', 'restart']:
    assert args[2] == app + '-machine'
elif args[:2] == ['ssh', 'console']:
    command = args[args.index('-C') + 1]
    words = shlex.split(command)
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
    _, _, op, _, _, source, target = args
    if op == 'get':
        shutil.copyfile(local(source), target)
        if os.environ.get('FAKE_BACKUP_CORRUPT'):
            with open(target, 'ab') as file:
                file.write(b'changed transport')
    elif op == 'put':
        shutil.copyfile(source, local(target))
    else:
        raise AssertionError(op)
else:
    raise AssertionError(args)
