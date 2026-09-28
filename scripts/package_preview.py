#!/usr/bin/env python3
"""Build a local ad-hoc preview from committed source and a trusted runtime App.

No network, key access, application launch, installation, or publication.
An existing runtime is an explicit build input, not a source of product code.
"""
from __future__ import annotations

import argparse
from email.parser import Parser
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import zipfile

from package_privacy import audit_zip, sanitize
from setup_models import checksum

if sys.flags.optimize:
    raise RuntimeError('Run release checks without Python optimization (-O).')

ROOT = Path(__file__).resolve().parents[1]
VERSION = '0.1.0-rc.5'


def run(arguments, *, cwd=ROOT, env=None, log=None):
    result = subprocess.run([str(arg) for arg in arguments], cwd=cwd, env=env,
                            capture_output=True, text=True)
    if log:
        Path(log).write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f'{arguments[0]} failed; inspect the local build report.')
    return result.stdout.strip()


def canonical(name):
    return re.sub(r'[-_.]+', '-', name).lower()


def versions(runtime):
    result = {}
    for metadata in (runtime / 'lib/python3.12/site-packages').glob('*.dist-info/METADATA'):
        parsed = Parser().parsestr(metadata.read_text())
        result[canonical(parsed['Name'])] = parsed['Version']
    return result


def verify_runtime(runtime):
    expected = {}
    for line in (ROOT / 'brain/runtime-requirements.lock').read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        name, version = line.split('==')
        expected[canonical(name)] = version
    actual = versions(runtime)
    mismatches = {name for name, version in expected.items() if actual.get(name) != version}
    extra = set(actual) - set(expected) - {'pip', 'setuptools', 'wheel'}
    if mismatches or extra:
        raise ValueError(f'Runtime dependency mismatch: {sorted(mismatches | extra)}')
    return actual


def payload_inventory(root):
    result = {}
    for path in root.rglob('*'):
        relative = str(path.relative_to(root))
        if path.name in {'.env', 'debug.log', 'dictations.json', 'history.json'} or path.name.startswith('.env.'):
            raise ValueError('Private file in runtime input: ' + relative)
        if path.is_symlink():
            if not path.resolve().is_relative_to(root.resolve()):
                raise ValueError('External runtime symlink: ' + relative)
            result[relative] = {'symlink': os.readlink(path)}
        elif path.is_file():
            result[relative] = {'sha256': checksum(path)}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-app', type=Path, required=True,
                        help='A trusted locally audited Liana.app providing runtime/models/licenses only.')
    parser.add_argument('--output-dir', type=Path, required=True,
                        help='A new directory; existing output is never overwritten.')
    args = parser.parse_args()
    output = args.output_dir.resolve()
    runtime_app = args.runtime_app.resolve()
    if output.exists() or output == ROOT or ROOT.is_relative_to(output) or output.is_relative_to(runtime_app):
        raise ValueError('Choose a new, separate output directory.')
    if run(['git', 'status', '--porcelain', '--untracked-files=normal']):
        raise ValueError('Commit and review the source before packaging.')
    commit = run(['git', 'rev-parse', 'HEAD'])
    tracked = run(['git', 'ls-files', '-z']).split('\0')
    tracked = [name for name in tracked if name]
    if any((ROOT / name).is_symlink() for name in tracked):
        raise ValueError('Review source symlinks before packaging.')
    source_hashes = {name: checksum(ROOT / name) for name in tracked}
    resources_in = runtime_app / 'Contents/Resources'
    runtime_in = resources_in / 'brain/.venv'
    run(['codesign', '--verify', '--deep', '--strict', runtime_app])
    dependencies = verify_runtime(runtime_in)
    runtime_hashes = payload_inventory(runtime_in)
    model_manifest = json.loads((ROOT / 'brain/model-manifest.json').read_text())
    for entry in model_manifest['groups']['first_release']['files']:
        model_file = resources_in / 'brain' / entry['path']
        if checksum(model_file) != entry['sha256']:
            raise ValueError('Input model checksum mismatch: ' + entry['path'])

    output.mkdir(parents=True)
    print('Building committed source ' + commit[:12], flush=True)
    run(['swift', 'build', '-c', 'release', '-Xswiftc', '-file-prefix-map', '-Xswiftc',
         f'{ROOT}=/LianaSource', '-Xswiftc', '-debug-prefix-map', '-Xswiftc', f'{ROOT}=/LianaSource'],
        cwd=ROOT / 'mac', log=output / 'build.log')
    binary_dir = Path(run(['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=ROOT / 'mac'))
    app = output / 'Liana.app'
    contents = app / 'Contents'
    resources = contents / 'Resources'
    brain = resources / 'brain'
    (contents / 'MacOS').mkdir(parents=True)
    brain.mkdir(parents=True)
    shutil.copy2(binary_dir / 'Liana', contents / 'MacOS/Liana')
    run(['strip', '-S', contents / 'MacOS/Liana'])
    info = plistlib.loads((ROOT / 'mac/Info.plist').read_bytes())
    info.update(CFBundleIconFile='Liana.icns', CFBundleExecutable='Liana', CFBundlePackageType='APPL')
    assert info['LianaReleaseVersion'] == VERSION and info['LSMinimumSystemVersion'] == '26.0'
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    shutil.copy2(ROOT / 'assets/Liana.icns', resources / 'Liana.icns')
    manifest = json.loads((ROOT / 'brain/runtime-manifest.json').read_text())
    for relative in manifest['brain_sources']:
        if relative not in source_hashes or not relative.startswith('brain/'):
            raise ValueError('Unexpected product source: ' + relative)
        target = resources / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, target)
        assert checksum(target) == source_hashes[relative]
    for name in ('runtime-manifest.json', 'model-manifest.json', 'runtime-requirements.lock', 'runtime-source-lock.json'):
        shutil.copy2(ROOT / 'brain' / name, brain / name)
    print('Copying verified runtime and models; original App is unchanged.', flush=True)
    shutil.copytree(runtime_in, brain / '.venv', symlinks=True)
    assert payload_inventory(brain / '.venv') == runtime_hashes
    for entry in model_manifest['groups']['first_release']['files']:
        target = brain / entry['path']
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(resources_in / 'brain' / entry['path'], target)
        assert checksum(target) == entry['sha256']
    shutil.copytree(resources_in / 'THIRD_PARTY_LICENSES', resources / 'THIRD_PARTY_LICENSES', symlinks=True)
    for name in ('LICENSE', 'THIRD_PARTY_NOTICES.md'):
        shutil.copy2(ROOT / name, resources / name)
    (resources / 'THIRD_PARTY_PYTHON_NOTICES.md').write_text(
        '# Bundled Python distributions\n\nLicense and copyright texts are preserved in '
        '`THIRD_PARTY_LICENSES/Python-Distributions/` and each installed distribution. '
        'Supplemental upstream licenses are in `THIRD_PARTY_LICENSES/`.\n\n' +
        '\n'.join(f'- {name} {version}' for name, version in sorted(dependencies.items())) + '\n')
    metadata = resources / 'RELEASE_METADATA'
    metadata.mkdir()
    (metadata / 'source-files-sha256.json').write_text(json.dumps(source_hashes, sort_keys=True, indent=2) + '\n')
    (metadata / 'build.json').write_text(json.dumps({
        'version': VERSION, 'source_commit': commit,
        'source_repository': 'https://github.com/Jameswzj-T/liana-releases',
        'signing': 'ad-hoc', 'apple_notarized': False,
        'platform': 'macOS 26+ Apple Silicon', 'python': '3.12.13',
        'private_history_included': False, 'clean_device_acceptance': 'not completed for this artifact',
    }, indent=2) + '\n')
    (resources / 'release-candidate-status.txt').write_text(
        f'Liana {VERSION} early preview\nAd-hoc signed. No Developer ID signature or Apple notarization.\n'
        'Local-first; cloud features require explicit configuration.\n'
        'New artifact installation, system permissions and microphone acceptance remain separate checks.\n')
    (output / 'sanitize.json').write_text(json.dumps(sanitize(app), indent=2) + '\n')
    reports = output / 'reports'
    reports.mkdir()
    environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'PYTHONDONTWRITEBYTECODE': '1',
                   'PYTHONNOUSERSITE': '1', 'HOME': str(output / 'isolated-home')}
    Path(environment['HOME']).mkdir()
    python = brain / '.venv/bin/python'
    print('Checking runtime relocation and native library paths.', flush=True)
    run([python, ROOT / 'scripts/audit_python_relocation.py', '--expected-root', brain / '.venv',
         '--output', reports / 'python-relocation.json'], env=environment, log=reports / 'python-check.log')
    relocation = json.loads((reports / 'python-relocation.json').read_text())
    if relocation['python']['version'] != '3.12.13' or relocation['python']['machine'] != 'arm64':
        raise ValueError('The bundled interpreter does not match Python 3.12.13 arm64.')
    audit_command = [python, ROOT / 'scripts/audit_macho_dependencies.py', '--root', app,
                     '--output', reports / 'macho.json']
    try:
        run(audit_command, env=environment, log=reports / 'macho-check.log')
    except RuntimeError:
        audit = json.loads((reports / 'macho.json').read_text())
        allowed_prefix = '/Applications/Xcode.app/Contents/Developer/Toolchains/'
        rpaths = audit['external_rpaths']
        if (audit['external_dependencies'] or audit['tool_errors'] or not rpaths
                or any(item['path'] != 'Contents/MacOS/Liana'
                       or not item['reference'].startswith(allowed_prefix)
                       or '/usr/lib/swift' not in item['reference'] for item in rpaths)):
            raise
        # Only a disposable, newly compiled executable is edited. The system's
        # Swift libraries remain available through its other load paths.
        for item in rpaths:
            run(['install_name_tool', '-delete_rpath', item['reference'], app / item['path']])
        (reports / 'removed-build-rpaths.json').write_text(json.dumps(rpaths, indent=2) + '\n')
        run(audit_command, env=environment, log=reports / 'macho-check.log')
    print('Signing local preview and checking the complete ZIP.', flush=True)
    native_paths = sorted({(app / item['path']).resolve()
                           for item in json.loads((reports / 'macho.json').read_text())['files']},
                          key=lambda path: len(path.parts), reverse=True)
    for native in native_paths:
        if not native.is_relative_to(app.resolve()):
            raise ValueError('Native signing target escaped the new bundle.')
        run(['codesign', '--force', '--sign', '-', native])
    run(['codesign', '--force', '--deep', '--sign', '-', app], log=reports / 'sign.log')
    run(['codesign', '--verify', '--deep', '--strict', app], log=reports / 'signature-check.log')
    requirement = subprocess.run(['codesign', '-d', '-r-', str(app)], capture_output=True, text=True)
    if requirement.returncode or 'designated => cdhash H"' not in requirement.stdout + requirement.stderr:
        raise ValueError('Ad-hoc preview must retain a code-hash-bound designated requirement.')
    for native in json.loads((reports / 'macho.json').read_text())['files']:
        run(['codesign', '--verify', '--strict', app / native['path']])
    archive = output / f'Liana-{VERSION}-macos-arm64.zip'
    run(['ditto', '-c', '-k', '--norsrc', '--noextattr', '--noqtn', '--keepParent', app, archive])
    with zipfile.ZipFile(archive) as opened:
        assert opened.testzip() is None
    privacy = audit_zip(archive)
    (reports / 'privacy.json').write_text(json.dumps(privacy, indent=2) + '\n')
    if not privacy['passed']:
        raise ValueError('Privacy audit failed; archive must not be uploaded.')
    assert payload_inventory(runtime_in) == runtime_hashes, 'Original runtime changed'
    assert {name: checksum(ROOT / name) for name in tracked} == source_hashes, 'Source changed during build'
    checksum_text = f'{checksum(archive)}  {archive.name}\n'
    (output / 'SHA256SUMS.txt').write_text(checksum_text)
    result = {'source_commit': commit, 'version': VERSION, 'archive': archive.name,
              'bytes': archive.stat().st_size, 'sha256': checksum(archive),
              'files': privacy['files'], 'privacy_passed': True, 'strict_signature_passed': True,
              'app_started': False, 'uploaded': False, 'notarized': False}
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
