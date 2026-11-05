import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import backup

HERE = Path(__file__).resolve().parent


class BackupTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='atlas-backup-proof-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.peer = self.root / 'fly-real'
        shutil.copy2(HERE / 'fake_fly.py', self.peer)
        self.peer.chmod(0o755)
        self.sha = '1' * 40
        self.manifest = subprocess.check_output(['git', 'show', backup.MASTER + ':rela/atlas.manifest.json'])
        core = subprocess.check_output(['git', 'show', backup.MASTER + ':fly/prod/core.json'])
        for app, name in backup.APPS.items():
            base = self.root / app
            (base / 'tmp').mkdir(parents=True)
            (base / 'data' / name).mkdir(parents=True)
            if name == 'rela':
                d = base / 'data/rela'
                (d / 'entities/issues').mkdir(parents=True)
                (d / 'entities/issues/IS-1.md').write_text('PRIVATE_RECORD_DO_NOT_PUBLISH')
                (d / 'relations').mkdir()
                (d / 'schema.yaml').write_text('entities: {}\n')
                (d / 'data-entry.yaml').write_text('{}\n')
                (d / 'atlas.json').write_text('{}\n')
                (d / 'atlas.manifest.json').write_bytes(self.manifest)
            else:
                d = base / 'data/beam'
                code = 'for p <- System.argv() do {:ok,t}=:dets.open_file(make_ref(),file: String.to_charlist(p)); :ok=:dets.insert(t,{:private,"PRIVATE_RECORD_DO_NOT_PUBLISH"}); :ok=:dets.close(t) end'
                subprocess.run(['elixir', '-e', code, str(d/'ledger.dets'), str(d/'links.dets')],
                               env=dict(os.environ, ELIXIR_ERL_OPTIONS='+S 1:1'), check=True, capture_output=True)
                config = base / 'app/fly/prod/core.json'
                config.parent.mkdir(parents=True)
                config.write_bytes(core)
        self.env = dict(os.environ, ATLAS_BACKUP_FLY=str(self.peer), FAKE_BACKUP_ROOT=str(self.root),
                        FAKE_BACKUP_MODULE=str(HERE), FAKE_BACKUP_MANIFEST=hashlib.sha256(self.manifest).hexdigest(),
                        ATLAS_FLY_TOKEN_CORE='synthetic-beam', ATLAS_FLY_TOKEN_RELA='synthetic-rela',
                        GITHUB_REF_NAME='atlas-prod-backup-' + self.sha, GITHUB_REPOSITORY='eyra/atlas',
                        GITHUB_EVENT_NAME='push', GITHUB_RUN_ID='private-test', ELIXIR_ERL_OPTIONS='+S 1:1')
        self.before = {app: backup.manifest(self.root/app/'data'/name) for app,name in backup.APPS.items()}
        self.original = backup.invoke

    def invoke(self, args, *a, **kw):
        if args[:1] == ['git'] and 'rev-parse' in args:
            return self.sha + '\n'
        if args[:1] == ['git'] and 'ls-remote' in args:
            return backup.MASTER+'\trefs/heads/master\n'+backup.ECC+'\t'+backup.RELEASE_REF+'\n'
        return self.original(args, *a, **kw)

    def execute(self, **changes):
        self.env.update(changes)
        output = self.root / 'output'
        with patch.dict(os.environ, self.env, clear=True), patch.object(backup, 'invoke', self.invoke):
            backup.main(output)
        return output

    def unchanged(self):
        for app, name in backup.APPS.items():
            self.assertEqual(self.before[app], backup.manifest(self.root/app/'data'/name))

    def released(self):
        for app in backup.APPS:
            self.assertFalse((self.root/app/'data/hold').exists())

    def test_complete_backup_retains_matching_pair_and_never_publishes_records(self):
        output = self.execute()
        proof = json.loads((output/'proof.json').read_text())
        self.assertEqual(proof['status'], 'complete')
        for name, component in proof['components'].items():
            path = self.root/component['app']/component['location'].lstrip('/')
            self.assertEqual(backup.digest(path), component['archive_sha256'])
            self.assertTrue(component['held_both'])
            completion = json.loads((path.parent/'complete.json').read_text())
            self.assertEqual(completion['components'], proof['components'])
            self.assertGreater(component['file_count'], 0)
        public = (output/'proof.json').read_text()
        for private in ['PRIVATE_RECORD_DO_NOT_PUBLISH', 'synthetic-beam', 'synthetic-rela']:
            self.assertNotIn(private, public)
        self.released(); self.unchanged()

    def test_preexisting_hold_is_refused_without_releasing_it(self):
        hold = self.root/'eyra-atlas/data/hold';hold.touch()
        with self.assertRaises(backup.Refused): self.execute()
        self.assertTrue(hold.exists())
        self.unchanged()

    def test_transport_corruption_refuses_proof_and_releases_own_holds(self):
        with self.assertRaises(backup.Refused): self.execute(FAKE_BACKUP_CORRUPT='1')
        self.assertFalse((self.root/'output/proof.json').exists())
        self.released(); self.unchanged()

    def test_retention_failure_never_publishes_completion(self):
        with self.assertRaises(backup.Refused): self.execute(FAKE_BACKUP_FAIL='sftp put')
        self.assertFalse((self.root/'output/proof.json').exists())
        self.released(); self.unchanged()

    def test_source_digest_mismatch_refuses_before_holding(self):
        with self.assertRaises(backup.Refused): self.execute(FAKE_BACKUP_WRONG_IMAGE='1')
        self.released(); self.unchanged()
        calls = (self.root/'calls.jsonl').read_text()
        self.assertNotIn('touch /data/hold', calls)

    def test_bad_trigger_refuses_before_fly_io(self):
        with self.assertRaises(backup.Refused): self.execute(GITHUB_REF_NAME='unreviewed')
        self.assertFalse((self.root/'calls.jsonl').exists())

    def test_other_app_or_missing_token_is_refused(self):
        with patch.dict(os.environ, self.env, clear=True):
            with self.assertRaises(backup.Refused): backup.fly(['status','-a','other-app','--json'])
            with self.assertRaises(backup.Refused): backup.fly(['deploy','-a','eyra-atlas'])
            del os.environ['ATLAS_FLY_TOKEN_CORE']
            with self.assertRaises(backup.Refused): backup.fly(['status','-a','eyra-atlas','--json'])
        self.assertFalse((self.root/'calls.jsonl').exists())

    def test_unreadable_state_is_not_a_verified_backup(self):
        file = self.root/'eyra-atlas/data/beam/ledger.dets';file.write_bytes(b'damaged')
        with self.assertRaises(backup.Refused): self.execute()
        self.assertFalse((self.root/'output/proof.json').exists())
        self.released()

    def test_changed_machine_is_not_released_as_this_operations_hold(self):
        pair = {'eyra-atlas-rela': {'machine': 'old', 'image': {'tag': 'old'}}}
        with patch.object(backup, 'fly', return_value=json.dumps({'Machines': [{'id': 'replacement', 'image_ref': {'tag': 'new'}}]})), patch.object(backup, 'remote') as call:
            with self.assertRaises(backup.Refused): backup.release_owned(pair)
            call.assert_not_called()

    def test_changed_release_head_is_refused_before_fly_io(self):
        def changed(args, *a, **kw):
            if args[0] == 'git' and 'ls-remote' in args: return backup.MASTER+'\trefs/heads/master\n'+'2'*40+'\t'+backup.RELEASE_REF+'\n'
            return self.invoke(args,*a,**kw)
        with patch.dict(os.environ,self.env,clear=True), patch.object(backup,'invoke',changed):
            with self.assertRaises(backup.Refused): backup.main(self.root/'output')
        self.assertFalse((self.root/'calls.jsonl').exists())

    def test_symlink_is_not_silently_omitted(self):
        folder=self.root/'files';folder.mkdir();(folder/'link').symlink_to('/not-a-backup-target')
        with self.assertRaises(backup.Refused): backup.manifest(folder)


if __name__ == '__main__': unittest.main()
