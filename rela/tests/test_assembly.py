import copy
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import assemble
import config
import profiles
from verify import verify


class AssemblyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'rela'
        shutil.copytree(ROOT, self.root)
        self.manifest = 'compositions/atlas-eyra/sources.json'
        self.schema = config.closure(self.root)[1]
        self.original = assemble.read(ROOT / 'tests/fixtures/baseline-atlas.json')

    def test_equivalence_and_freshness(self):
        result = assemble.build(self.root, self.manifest)
        self.assertEqual({k: v for k, v in result.items() if k != "shell"}, self.original)
        self.assertEqual(result["shell"]["title"], "Atlas Console")
        assemble.build(self.root, self.manifest, check=True)
        path = self.root / 'modules/foundation/atlas.json'
        path.write_text(path.read_text() + '\n')
        with self.assertRaisesRegex(config.ConfigError, 'stale generated'):
            assemble.build(self.root, self.manifest, check=True)

    def test_shell_navigation_references_and_uniqueness(self):
        extra = assemble.build(self.root, self.manifest)
        for mutate in [
            lambda s: s['tabs'].append(dict(s['tabs'][0])),
            lambda s: s['tabs'][0].update({'to': '/k/missing'}),
            lambda s: s['tabs'][0].update({'to': '/k/scene/new'}),
            lambda s: s['tabs'][0].update({'assigned': 'true'}),
            lambda s: s['tabs'][0].update({'layout': 'terminal'}),
            lambda s: s.update({'tabs': []}),
        ]:
            bad = copy.deepcopy(extra)
            mutate(bad['shell'])
            with self.assertRaises(config.ConfigError):
                assemble.validate(bad, self.schema)

    def test_duplicate_leaves_arrays_and_json_keys(self):
        for value in [1, [], 'text', {}]:
            with self.assertRaisesRegex(config.ConfigError, 'duplicate'):
                assemble.combine({'a': value}, {'a': value})
        with self.assertRaisesRegex(config.ConfigError, 'duplicate JSON'):
            json.loads('{"a":1,"a":1}', object_pairs_hook=assemble.unique)
        self.assertEqual(assemble.combine({'a': {'b': 1}}, {'a': {'c': 2}}), {'a': {'b': 1, 'c': 2}})

    def test_negative_references_unknown_keys_and_structural_overwrites(self):
        mutations = [
            lambda x: x.update({'mystery': {}}),
            lambda x: x['entities']['issue'].update({'plural': 'wrong'}),
            lambda x: x['entities']['issue']['properties'].update({'title': {'type': 'boolean'}}),
            lambda x: x['relations']['assignment'].update({'from': ['person']}),
            lambda x: x['entities']['issue']['create']['ask'].append('missing'),
            lambda x: x['entities']['scene']['progress'].update({'over': 'missing'}),
            lambda x: x['runtime']['turn'].pop('outcome'),
            lambda x: x['runtime'].pop('turn'),
            lambda x: x['progress']['order'].append('unknown'),
            lambda x: x['runtime']['turn'].update({'outcome': 'missing'}),
            lambda x: x['flows']['build_and_merge'].update({'handover_field': 'missing'}),
            lambda x: x['flows']['build_and_merge'].pop('handover_field'),
            lambda x: x['flows'].update({'overlap': copy.deepcopy(x['flows']['build_and_merge'])}),
            lambda x: x['entities']['agent']['start'].update({'key': 's'}),
            lambda x: x['relations']['done_in'].update({'parent': True}),
        ]
        for mutate in mutations:
            extra = copy.deepcopy(self.original)
            mutate(extra)
            with self.assertRaises((config.ConfigError, KeyError)):
                assemble.validate(extra, self.schema)
        with self.assertRaisesRegex(config.ConfigError, 'missing actor'):
            assemble.validate(self.original, self.schema, {'agent': [], 'person': []})

    def test_failure_retains_previous_artifacts(self):
        before = (self.root / 'atlas.json').read_bytes()
        extra = self.root / 'compositions/atlas-eyra/atlas.json'
        contents = assemble.read(extra)
        contents['flows']['build_and_merge']['states'][-1]['next'] = ['nowhere']
        profiles.write(extra, contents)
        with self.assertRaises(assemble.subprocess.CalledProcessError):
            assemble.build(self.root, self.manifest)
        self.assertEqual((self.root / 'atlas.json').read_bytes(), before)

    def test_foundation_and_incident_omit_eyra(self):
        for profile in ['foundation', 'incident']:
            target = profiles.make(profile, Path(self.tmp.name) / profile)
            _, schema = config.closure(target)
            self.assertNotIn('scene', schema['entities'])
            self.assertNotIn('use_case', schema['entities'])
            self.assertNotIn('accepted_by', schema['relations'])
            extra = assemble.read(target / 'atlas.json')
            self.assertNotIn('test_and_accept', extra.get('flows', {}))
            if profile == 'foundation':
                self.assertNotIn('issue', schema['entities'])
                self.assertNotIn('pull_request', schema['entities'])
                self.assertNotIn('agent_request', schema['entities'])
            else:
                self.assertIn('incident', schema['entities'])
            binary = Path(__import__('os').environ.get('ATLAS_E2E_RELA_BIN', str(Path.home() / '.local/share/atlas/test/bin'))) / 'rela'
            if binary.exists():
                assemble.subprocess.run([str(binary), '--project', str(target), '--quiet', 'validate'], check=True)

    def test_packaged_provenance_and_missing_inputs(self):
        assembled = assemble.build(self.root, self.manifest)
        dest = Path(self.tmp.name) / 'package'
        config.package(self.root, dest)
        verify(dest)
        (dest / 'modules/foundation/atlas.json').unlink()
        with self.assertRaises(OSError):
            verify(dest)
        (self.root / 'atlas.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'stale generated'):
            verify(self.root)

    def test_manifest_missing_unsafe_sources_and_unknown_keys(self):
        path = self.root / self.manifest
        original = assemble.read(path)
        for source in ['missing.json', '../outside.json']:
            changed = copy.deepcopy(original)
            changed['sources'] = [source]
            profiles.write(path, changed)
            with self.assertRaises((config.ConfigError, OSError)):
                assemble.build(self.root, self.manifest)
        changed = copy.deepcopy(original)
        changed['unknown'] = True
        profiles.write(path, changed)
        with self.assertRaisesRegex(config.ConfigError, 'unknown keys'):
            assemble.build(self.root, self.manifest)

    def test_incident_profile_refuses_populated_eyra_data(self):
        import contextlib, io, os
        incident = profiles.make('incident', Path(self.tmp.name) / 'incident')
        data = Path(self.tmp.name) / 'populated'
        config.package(self.root, data)
        (data / 'entities/scenes').mkdir(parents=True)
        file = data / 'entities/scenes/SC-Atlas-01.md'
        before = b'---\nid: SC-Atlas-01\ntype: scene\ntitle: Keep this existing work\n---\n'
        file.write_bytes(before)
        binary = Path(os.environ.get('ATLAS_E2E_RELA_BIN', str(Path.home() / '.local/share/atlas/test/bin'))) / 'rela'
        if not binary.exists():
            self.skipTest('pinned rela not installed')
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertFalse(config.fits(incident, data, str(binary)))
        self.assertIn('scenes', output.getvalue())
        self.assertEqual(file.read_bytes(), before)

    def test_both_image_recipes_package_matching_closure_without_facts(self):
        import shlex
        for part in ['entities', 'relations']:
            (self.root / part).mkdir(exist_ok=True)
            (self.root / part / 'private-fact.md').write_text('Never package this fact')
        for recipe in ['core', 'rela']:
            image = Path(self.tmp.name) / recipe
            # Exercise only COPY's repository-owned configuration inputs in the recipes.
            # verify() then detects missing schema/fragment/generated files in either app.
            instructions = (ROOT.parent / f'fly/{recipe}.Dockerfile').read_text().splitlines()
            for line in instructions:
                if not line.startswith('COPY rela/'):
                    continue
                *sources, target = shlex.split(line)[1:]
                target = image / target.lstrip('/')
                directory_target = str(line).endswith('/') or len(sources) > 1
                for source in sources:
                    src = self.root / Path(source).relative_to('rela')
                    dest = target / src.name if directory_target else target
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    if src.is_dir():
                        shutil.copytree(src, dest, dirs_exist_ok=True)
                    else:
                        shutil.copy(src, dest)
            verify(image / 'app/rela')
            self.assertTrue((image / 'app/rela/scripts/verify.py').exists())
            self.assertFalse((image / 'app/rela/entities').exists())
            self.assertFalse((image / 'app/rela/relations').exists())
