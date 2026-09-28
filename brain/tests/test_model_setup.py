"""Offline download-helper tests; all data is generated in temporary directories."""
import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest

path = Path(__file__).resolve().parents[2] / 'scripts/setup_models.py'
spec = importlib.util.spec_from_file_location('model_setup', path)
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class ModelSetupTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='liana-model-test-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.data = b'synthetic model fixture, not actual model weights'
        self.item = {'target': self.root / 'example.bin', 'url': 'https://example.invalid/model',
                     'sha256': hashlib.sha256(self.data).hexdigest()}

    def fake_download(self, *args, **kwargs):
        return io.BytesIO(self.data)

    def forbidden_download(self, *args, **kwargs):
        self.fail('Network must not be attempted for existing files')

    def test_download_and_verify(self):
        self.assertEqual(setup.ensure_model(self.item, self.fake_download), 'downloaded and verified')
        self.assertEqual(self.item['target'].read_bytes(), self.data)
        self.assertEqual(len(list(self.root.iterdir())), 1)

    def test_existing_good_file_is_reused(self):
        self.item['target'].write_bytes(self.data)
        self.assertEqual(setup.ensure_model(self.item, self.forbidden_download), 'verified existing')

    def test_existing_bad_file_is_not_overwritten(self):
        self.item['target'].write_bytes(b'keep this existing file')
        with self.assertRaises(ValueError):
            setup.ensure_model(self.item, self.forbidden_download)
        self.assertEqual(self.item['target'].read_bytes(), b'keep this existing file')

    def test_bad_download_is_not_installed(self):
        self.item['sha256'] = '0' * 64
        with self.assertRaises(ValueError):
            setup.ensure_model(self.item, self.fake_download)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_race_does_not_overwrite_target(self):
        def race(*args, **kwargs):
            self.item['target'].write_bytes(b'another process')
            return self.fake_download()
        with self.assertRaises(FileExistsError):
            setup.ensure_model(self.item, race)
        self.assertEqual(self.item['target'].read_bytes(), b'another process')

    def test_failed_request_removes_only_temporary_file(self):
        def failed(*args, **kwargs):
            raise OSError('synthetic failure')
        with self.assertRaises(OSError):
            setup.ensure_model(self.item, failed)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_plan_rejects_parent_escape(self):
        manifest = {'groups': {'first_release': {'root': 'brain', 'files': [
            {'path': '../outside', 'source': 'example', 'sha256': '0' * 64}]}},
            'sources': {'example': {'source': 'https://example.invalid/model'}}}
        with self.assertRaises(ValueError):
            setup.model_plan(manifest, {'brain': self.root})

    def test_supported_manifest_has_eight_files(self):
        import json
        manifest = json.loads((path.parents[1] / 'brain/model-manifest.json').read_text())
        plan = setup.model_plan(manifest, {'brain': self.root / 'brain', 'app_support': self.root / 'support'})
        self.assertEqual(len(plan), 8)
        self.assertTrue(all(item['url'].startswith('https://') for item in plan))
        self.assertTrue(all(len(item['sha256']) == 64 for item in plan))


if __name__ == '__main__':
    unittest.main()
