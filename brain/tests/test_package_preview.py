"""Offline preview-input checks using only disposable, synthetic directories.

No App, model, credential store, or real runtime is inspected by these tests.
Run with Python 3.12 from the repository root:
    python3.12 -B -S -m unittest discover -s brain/tests -p 'test_package_preview.py' -v
"""

import hashlib
from pathlib import Path
import sys
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


if __name__ == "__main__":
    unittest.main()
