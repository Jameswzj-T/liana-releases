#!/usr/bin/env python3
"""Offline source sanity checks. This is not a complete privacy/security audit."""
import ast
import json
import plistlib
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOTS = ('brain/core', 'brain/tests', 'brain/tools', 'mac/Sources', 'mac/Tests', 'scripts')
SENSITIVE = (
    re.compile(r'(?:sk|AKIA)-?[A-Za-z0-9_\-]{24,}'),
    re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    re.compile(r'/' + r'Users/[^/\s]+/'),
)


def main() -> int:
    files = {ROOT / 'brain/daemon.py', ROOT / 'mac/Package.swift', ROOT / 'mac/Info.plist'}
    for directory in SOURCE_ROOTS:
        files.update(path for path in (ROOT / directory).rglob('*')
                     if path.is_file() and path.suffix in {'.py', '.swift'})
    errors = []
    for path in sorted(files):
        relative = str(path.relative_to(ROOT))
        if path.is_symlink():
            errors.append(relative + ': symlink not allowed')
            continue
        text = path.read_text()
        if any(pattern.search(text) for pattern in SENSITIVE):
            errors.append(relative + ': potential private material; inspect locally')
        if path.suffix == '.py':
            try:
                ast.parse(text, filename=relative)
            except SyntaxError:
                errors.append(relative + ': invalid Python syntax')
    plistlib.loads((ROOT / 'mac/Info.plist').read_bytes())
    manifest = json.loads((ROOT / 'brain/runtime-manifest.json').read_text())
    expected = set(manifest['brain_sources'])
    actual = {'brain/daemon.py'} | {str(path.relative_to(ROOT)) for path in (ROOT / 'brain/core').glob('*.py')}
    if expected != actual:
        errors.append('Runtime source inventory mismatch')
    for error in errors:
        print(error)
    print(f'Checked {len(files)} source files; {len(errors)} blocking findings. No network or user data accessed.')
    return 1 if errors else 0


if __name__ == '__main__':
    raise SystemExit(main())
