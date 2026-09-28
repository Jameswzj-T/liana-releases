#!/usr/bin/env python3
"""Plan or explicitly download the supported, hash-verified local models."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
from urllib.parse import quote, urlparse
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]


def checksum(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def model_plan(manifest: dict, roots: dict[str, Path]) -> list[dict]:
    group = manifest['groups']['first_release']
    result = []
    for item in group['files']:
        relative = Path(item['path'])
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Model paths must stay within their declared root.')
        root = roots[item.get('root', group['root'])].resolve()
        target = root / relative
        if target.is_symlink() or not target.resolve().is_relative_to(root):
            raise ValueError('Refusing a model path redirected outside its root.')
        upstream = manifest['sources'][item['source']]
        url = upstream['source']
        if 'revision' in upstream:
            url += '/resolve/' + quote(upstream['revision'], safe='') + '/' + quote(relative.name, safe='')
        if urlparse(url).scheme != 'https':
            raise ValueError('Model downloads must use HTTPS.')
        digest = item['sha256']
        if len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
            raise ValueError('Invalid model SHA-256.')
        result.append({'target': target, 'url': url, 'sha256': digest})
    return result


def ensure_model(item: dict, opener=urlopen) -> str:
    target = item['target']
    if target.exists():
        if not target.is_file() or checksum(target) != item['sha256']:
            raise ValueError(f'Existing model differs; it was not overwritten: {target.name}')
        return 'verified existing'
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix='.liana-download-', dir=target.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, 'wb') as output, opener(item['url'], timeout=60) as response:
            for chunk in iter(lambda: response.read(1024 * 1024), b''):
                output.write(chunk)
        if checksum(temporary) != item['sha256']:
            raise ValueError(f'Download failed SHA-256 verification: {target.name}')
        # Linking is atomic and refuses an existing destination, including a race.
        os.link(temporary, target)
        return 'downloaded and verified'
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--download', action='store_true', help='Explicitly permit network downloads.')
    args = parser.parse_args()
    manifest = json.loads((ROOT / 'brain/model-manifest.json').read_text())
    roots = {'brain': ROOT / 'brain',
             'app_support': Path.home() / 'Library/Application Support/VoiceFlow'}
    try:
        items = model_plan(manifest, roots)
        if not args.download:
            for item in items:
                print(f"{item['url']}\n  -> {item['target']}")
            print('Plan only. Add --download to fetch and verify these files. No service API Key is required.')
            return 0
        for item in items:
            print(f"{item['target'].name}: {ensure_model(item)}", flush=True)
        return 0
    except (OSError, ValueError, KeyError) as error:
        print(f'Model setup stopped: {error}')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
