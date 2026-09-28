"""Offline preview-input checks using only disposable, synthetic directories.

No App, model, credential store, or real runtime is inspected by these tests.
Run with Python 3.12 from the repository root:
    python3.12 -B -S -m unittest discover -s brain/tests -p 'test_package_preview.py' -v
"""

import hashlib
import json
from pathlib import Path
import sys
import subprocess
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch


SCRIPTS = str(Path(__file__).resolve().parents[2] / "scripts")
if SCRIPTS not in sys.path:
    sys.path.insert(0, SCRIPTS)

import package_preview


class PreviewRuntimeInputTests(unittest.TestCase):
    def setUp(self):
        temporary = TemporaryDirectory(prefix="liana-preview-test-")
        self.addCleanup(temporary.cleanup)
        self.sandbox = Path(temporary.name)
        self.repository = self.sandbox / "repository"
        self.runtime = self.sandbox / "runtime"
        self.site_packages = self.runtime / "lib/python3.12/site-packages"
        (self.repository / "brain").mkdir(parents=True)
        self.site_packages.mkdir(parents=True)
        (self.repository / "brain/runtime-requirements.lock").write_text(
            "# Synthetic dependencies only\n\ndemo_pkg==1.2.3\nhelper-lib==4.5.6\n",
            encoding="utf-8",
        )
        root_patch = patch.object(package_preview, "ROOT", self.repository)
        root_patch.start()
        self.addCleanup(root_patch.stop)

    def add_distribution(self, name, version):
        directory = self.site_packages / f"{name}-{version}.dist-info"
        directory.mkdir()
        (directory / "METADATA").write_text(
            f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n",
            encoding="utf-8",
        )

    def add_expected_distributions(self):
        self.add_distribution("Demo.Pkg", "1.2.3")
        self.add_distribution("helper-lib", "4.5.6")

    def test_correct_versions_and_allowed_install_tools_pass(self):
        self.add_expected_distributions()
        for name in ("pip", "setuptools", "wheel"):
            self.add_distribution(name, "1.0")
        self.assertEqual(
            package_preview.verify_runtime(self.runtime),
            {
                "demo-pkg": "1.2.3",
                "helper-lib": "4.5.6",
                "pip": "1.0",
                "setuptools": "1.0",
                "wheel": "1.0",
            },
        )

    def test_missing_dependency_is_rejected(self):
        self.add_distribution("Demo.Pkg", "1.2.3")
        with self.assertRaisesRegex(ValueError, "Runtime dependency mismatch.*helper-lib"):
            package_preview.verify_runtime(self.runtime)

    def test_wrong_dependency_version_is_rejected(self):
        self.add_distribution("Demo.Pkg", "9.9.9")
        self.add_distribution("helper-lib", "4.5.6")
        with self.assertRaisesRegex(ValueError, "Runtime dependency mismatch.*demo-pkg"):
            package_preview.verify_runtime(self.runtime)

    def test_unexpected_dependency_is_rejected(self):
        self.add_expected_distributions()
        self.add_distribution("extra-lib", "1.0")
        with self.assertRaisesRegex(ValueError, "Runtime dependency mismatch.*extra-lib"):
            package_preview.verify_runtime(self.runtime)


class PreviewPayloadInventoryTests(unittest.TestCase):
    def setUp(self):
        temporary = TemporaryDirectory(prefix="liana-payload-test-")
        self.addCleanup(temporary.cleanup)
        self.sandbox = Path(temporary.name)
        self.payload = self.sandbox / "payload"
        self.payload.mkdir()

    def test_regular_files_and_internal_symlink_have_exact_inventory(self):
        nested = self.payload / "lib"
        nested.mkdir()
        content = b"synthetic payload\n"
        (nested / "sample.txt").write_bytes(content)
        (self.payload / "sample-link").symlink_to("lib/sample.txt")
        self.assertEqual(
            package_preview.payload_inventory(self.payload),
            {
                "lib/sample.txt": {"sha256": hashlib.sha256(content).hexdigest()},
                "sample-link": {"symlink": "lib/sample.txt"},
            },
        )

    def test_symlink_to_file_outside_payload_is_rejected(self):
        outside = self.sandbox / "outside.txt"
        outside.write_text("synthetic data only", encoding="utf-8")
        (self.payload / "escape").symlink_to("../outside.txt")
        with self.assertRaisesRegex(ValueError, "External runtime symlink: escape"):
            package_preview.payload_inventory(self.payload)

    def test_symlink_to_directory_outside_payload_is_rejected(self):
        outside = self.sandbox / "outside-directory"
        outside.mkdir()
        (self.payload / "escape-directory").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "External runtime symlink: escape-directory"):
            package_preview.payload_inventory(self.payload)

    def test_private_filenames_are_rejected_even_in_nested_directories(self):
        for name in (".env", ".env.local", "debug.log", "dictations.json", "history.json"):
            with self.subTest(name=name):
                case = self.payload / name.replace(".", "_")
                nested = case / "nested"
                nested.mkdir(parents=True)
                (nested / name).write_text("synthetic data only", encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "Private file in runtime input"):
                    package_preview.payload_inventory(case)

    def test_private_filename_on_internal_symlink_is_rejected(self):
        (self.payload / "ordinary.txt").write_text("synthetic data only", encoding="utf-8")
        (self.payload / ".env.local").symlink_to("ordinary.txt")
        with self.assertRaisesRegex(ValueError, "Private file in runtime input"):
            package_preview.payload_inventory(self.payload)


class PreviewSpeakerInputTests(unittest.TestCase):
    def setUp(self):
        temporary = TemporaryDirectory(prefix='liana-speaker-input-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.resources = self.root / 'Resources'
        self.file = self.resources / 'brain' / package_preview.SPEAKER_MODEL
        self.file.parent.mkdir(parents=True)
        self.data = b'synthetic speaker model, no audio or biometrics'
        self.file.write_bytes(self.data)
        self.entry = {'path': package_preview.SPEAKER_MODEL, 'source': 'synthetic',
                      'sha256': hashlib.sha256(self.data).hexdigest(), 'size': len(self.data)}
        self.manifest = {'sources': {'synthetic': {'release_status': 'allowed', 'license_status': 'confirmed'}},
                         'groups': {'first_release': {'files': [self.entry]}}}

    def test_bundled_and_explicit_models_both_require_matching_hash(self):
        self.assertEqual(package_preview.verified_models(self.resources, self.manifest),
                         {package_preview.SPEAKER_MODEL: self.file.resolve()})
        supplied = self.root / 'supplied.onnx'
        supplied.write_bytes(self.data)
        self.assertEqual(package_preview.verified_models(self.resources, self.manifest, supplied),
                         {package_preview.SPEAKER_MODEL: supplied})
        supplied.write_bytes(b'wrong model')
        with self.assertRaisesRegex(ValueError, 'checksum/size mismatch'):
            package_preview.verified_models(self.resources, self.manifest, supplied)

    def test_missing_model_or_inventory_entry_stops_packaging(self):
        with self.assertRaisesRegex(ValueError, 'Missing input model'):
            package_preview.verified_models(self.resources, self.manifest, self.root / 'absent.onnx')
        self.manifest['groups']['first_release']['files'] = []
        with self.assertRaisesRegex(ValueError, 'missing the speaker model'):
            package_preview.verified_models(self.resources, self.manifest)

    def test_unconfirmed_license_stops_packaging(self):
        self.manifest['sources']['synthetic']['license_status'] = 'unconfirmed'
        with self.assertRaisesRegex(ValueError, 'redistribution is not confirmed'):
            package_preview.verified_models(self.resources, self.manifest)

    def test_model_symlink_is_not_accepted_as_explicit_input(self):
        supplied = self.root / 'supplied.onnx'
        supplied.symlink_to(self.file)
        with self.assertRaisesRegex(ValueError, 'redirected link'):
            package_preview.verified_models(self.resources, self.manifest, supplied)

    def test_manifest_path_cannot_escape_or_repeat(self):
        for bad in ['../outside.onnx', '/outside.onnx']:
            self.entry['path'] = bad
            with self.assertRaisesRegex(ValueError, 'Invalid or duplicate'):
                package_preview.verified_models(self.resources, self.manifest)
        self.entry['path'] = package_preview.SPEAKER_MODEL
        self.manifest['groups']['first_release']['files'].append(dict(self.entry))
        with self.assertRaisesRegex(ValueError, 'Invalid or duplicate'):
            package_preview.verified_models(self.resources, self.manifest)

    def test_model_inventory_contains_actual_speaker_path_and_license(self):
        repository = Path(__file__).resolve().parents[2]
        manifest = json.loads((repository / 'brain/model-manifest.json').read_text())
        entry = next(e for e in manifest['groups']['first_release']['files']
                     if e['path'] == package_preview.SPEAKER_MODEL)
        source = manifest['sources'][entry['source']]
        self.assertEqual(entry['sha256'], 'aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2')
        self.assertEqual(source['license_status'], 'confirmed')
        self.assertTrue((repository / 'THIRD_PARTY_LICENSES' / source['license_file']).is_file())

    def test_speaker_smoke_refuses_optimized_mode_before_accessing_any_model(self):
        script = Path(SCRIPTS) / 'smoke_speaker.py'
        result = subprocess.run([sys.executable, '-B', '-O', str(script), '--help'],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('without Python optimization', result.stderr)

    def test_new_license_is_copied_and_old_runtime_notices_retained(self):
        repository = self.root / 'repository'
        new_license = repository / 'THIRD_PARTY_LICENSES/CAMplusplus-Apache-2.0.txt'
        new_license.parent.mkdir(parents=True)
        new_license.write_bytes(b'synthetic new license')
        old_licenses = self.root / 'old-licenses'
        old_licenses.mkdir()
        (old_licenses / 'runtime.txt').write_bytes(b'preserve this runtime notice')
        source_hashes = {'THIRD_PARTY_LICENSES/CAMplusplus-Apache-2.0.txt': package_preview.checksum(new_license)}
        target = self.root / 'new-licenses'
        with patch.object(package_preview, 'ROOT', repository):
            package_preview.copy_reviewed_licenses(old_licenses, target, source_hashes)
        self.assertEqual((target / 'runtime.txt').read_bytes(), b'preserve this runtime notice')
        self.assertEqual((target / new_license.name).read_bytes(), new_license.read_bytes())


if __name__ == "__main__":
    unittest.main()
