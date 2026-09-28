"""Sanitize a newly assembled App, then fail closed on unsafe final ZIP contents.

Never reads credentials or user data. Reports names/categories, never matching values.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile

HOME_PATH = re.compile(rb"/(?:Users|home)/[^/\s\x00\"'<>]+")
SECRET = re.compile(rb"(?<![A-Za-z0-9_-])sk-(?:ws-)?[A-Za-z0-9_-]{24,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----\r?\n[A-Za-z0-9+/]{32,}")
PRIVATE_NAMES = {".env", "debug.log", "dictations.json", "history.json", "voiceflow_rec.wav"}


def sanitize(app: Path):
    app = app.resolve()
    if app.suffix != ".app" or not (app / "Contents/Info.plist").is_file():
        raise ValueError("Expected an assembled .app, never a source/runtime directory")
    venv = app / "Contents/Resources/brain/.venv"
    counts = {"bytecode_removed": 0, "entrypoints_relocated": 0, "metadata_redacted": 0}
    for path in app.rglob("*"):
        if path.is_symlink():
            if not path.resolve().is_relative_to(app):
                raise ValueError("External symlink in candidate: " + str(path.relative_to(app)))
            continue
        if path.suffix == ".pyc":
            source = (path.parent.parent / (path.name.split(".cpython-")[0] + ".py")
                      if path.parent.name == "__pycache__" else path.with_suffix(".py"))
            if not source.is_file():
                raise ValueError("Cannot remove source-less bytecode: " + str(path.relative_to(app)))
            path.unlink()  # Only a disposable candidate's regenerable cache.
            counts["bytecode_removed"] += 1
    for path in (venv / "bin").iterdir():
        if path.is_symlink() or not path.is_file():
            continue
        data = path.read_bytes()
        first, separator, body = data.partition(b"\n")
        if first.startswith(b"#!/") and b"python" in first and HOME_PATH.search(first):
            wrapper = b'#!/bin/sh\n\'\'\'exec\' "$(dirname -- "$(realpath -- "$0")")/python3.12" "$0" "$@"\n\' \'\'\'\n'
            path.write_bytes(wrapper + body)
            counts["entrypoints_relocated"] += 1
    for path in (app / "Contents/Resources/RELEASE_METADATA").glob("*.json"):
        data = path.read_bytes()
        cleaned = HOME_PATH.sub(b"<BUILD_HOME>", data)
        if data != cleaned:
            json.loads(cleaned)  # Never silently damage the machine-readable evidence.
            path.write_bytes(cleaned)
            counts["metadata_redacted"] += 1
    return counts


def audit_zip(archive: Path, private_prefix: bytes | None = None):
    private_prefix = private_prefix or str(Path.home()).encode()
    findings = []
    vendor_path_files = []
    files = 0
    with zipfile.ZipFile(archive) as zf:
        for item in zf.infolist():
            if item.is_dir():
                continue
            files += 1
            name = item.filename
            path = Path(name)
            categories = set()
            vendor_path = False
            third_party = "/brain/.venv/" in name
            if path.name in PRIVATE_NAMES or path.name.startswith(".env."):
                categories.add("private_file")
            if "__MACOSX" in path.parts or path.name.startswith("._"):
                categories.add("resource_fork")
            if path.is_absolute() or ".." in path.parts:
                categories.add("unsafe_archive_path")
            if HOME_PATH.search(name.encode()):
                categories.add("local_home_path")
            with zf.open(item) as stream:
                tail = b""
                while block := stream.read(1024 * 1024):
                    data = tail + block
                    if private_prefix in data or (HOME_PATH.search(data) and not third_party):
                        categories.add("local_home_path")
                    elif HOME_PATH.search(data):
                        vendor_path = True
                    if SECRET.search(data):
                        categories.add("credential_pattern")
                    tail = data[-512:]
            if categories:
                findings.append({"file": name, "categories": sorted(categories)})
            if vendor_path:
                vendor_path_files.append(name)
    return {"files": files, "findings": findings, "passed": not findings,
            "third_party_path_warnings": vendor_path_files,
            "scope": "private filenames, this build user's home path, non-vendor home paths, credential patterns, archive metadata; vendor/example paths reported separately; no credential store read"}


def source_manifest(root: Path):
    # Include the actual build inputs; never walk project evidence, .env, or user data.
    paths = list((root / "mac/Sources").rglob("*.swift"))
    paths += list((root / "brain/core").glob("*.py"))
    paths += list((root / "scripts").glob("*.py")) + list((root / "scripts").glob("*.sh"))
    paths += [root / p for p in ("mac/Package.swift", "mac/Info.plist", "brain/daemon.py",
                               "brain/runtime-manifest.json", "brain/model-manifest.json")]
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(set(paths)) if p.is_file()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sanitize", type=Path)
    parser.add_argument("--zip", type=Path)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if sum(x is not None for x in (args.sanitize, args.zip, args.source)) != 1:
        parser.error("Choose one action")
    report = sanitize(args.sanitize) if args.sanitize else (audit_zip(args.zip) if args.zip else source_manifest(args.source))
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    if args.zip:
        print(json.dumps({"files": report["files"], "findings": len(report["findings"]), "passed": report["passed"]}))
        return 0 if report["passed"] else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
