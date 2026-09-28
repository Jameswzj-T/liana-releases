#!/usr/bin/env python3
"""Verify that a copied standalone Python resolves its runtime from the new root."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import lzma
from pathlib import Path
import platform
import sqlite3
import ssl
import sys
import sysconfig


def inside(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-root", type=Path, required=True)
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--source-build")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    root = args.expected_root.resolve()
    executable = Path(sys.executable).resolve()
    prefix = Path(sys.prefix).resolve()
    base_prefix = Path(sys.base_prefix).resolve()
    stdlib = Path(sysconfig.get_path("stdlib")).resolve()
    absolute_sys_paths = [Path(item).resolve() for item in sys.path if item and Path(item).is_absolute()]
    # Running this verifier by file path legitimately adds its own scripts/ directory
    # to sys.path[0]. That is an invocation detail, not a Python runtime dependency.
    verifier_dir = Path(sys.argv[0]).resolve().parent
    external_runtime_paths = [
        item for item in absolute_sys_paths if item != verifier_dir and not inside(item, root)
    ]
    external_symlinks: list[dict[str, str]] = []
    for item in root.rglob("*"):
        if not item.is_symlink():
            continue
        try:
            target = item.resolve(strict=False)
        except OSError as exc:
            external_symlinks.append({"path": str(item), "target": f"ERROR: {exc}"})
            continue
        if not inside(target, root):
            external_symlinks.append({"path": str(item), "target": str(target)})

    checks = {
        "executable_inside_staging": inside(executable, root),
        "prefix_is_staging": prefix == root,
        "base_prefix_is_staging": base_prefix == root,
        "stdlib_inside_staging": inside(stdlib, root),
        "sys_path_has_no_external_runtime_entries": not external_runtime_paths,
        "tree_has_no_external_symlinks": not external_symlinks,
        "ssl_works": len(ssl.RAND_bytes(8)) == 8,
        "sqlite_works": sqlite3.connect(":memory:").execute("select 1").fetchone() == (1,),
        "lzma_works": lzma.decompress(lzma.compress(b"liana")) == b"liana",
        "hashlib_works": hashlib.sha256(b"liana").hexdigest()
        == "37976d6f82acb82f683f71884a9f0cf601826b5e43abdcdffe85d9f435edf3e7",
    }

    imports: dict[str, str] = {}
    for name in ("ctypes", "ensurepip", "multiprocessing", "venv"):
        try:
            module = __import__(name)
            imports[name] = getattr(module, "__file__", "built-in") or "built-in"
        except Exception as exc:  # pragma: no cover - reported as staging evidence
            imports[name] = f"ERROR: {type(exc).__name__}: {exc}"
            checks[f"import_{name}"] = False
        else:
            checks[f"import_{name}"] = True

    report = {
        "schema_version": 1,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "source": {
            "root": str(args.source_root.resolve()) if args.source_root else None,
            "build": args.source_build,
        },
        "staging": {
            "root": str(root),
            "executable": str(executable),
            "prefix": str(prefix),
            "base_prefix": str(base_prefix),
            "stdlib": str(stdlib),
            "sys_path": [str(item) for item in absolute_sys_paths],
            "ignored_verifier_path": str(verifier_dir),
            "external_runtime_paths": [str(item) for item in external_runtime_paths],
            "external_symlinks": external_symlinks,
        },
        "python": {
            "version": platform.python_version(),
            "implementation": platform.python_implementation(),
            "machine": platform.machine(),
            "platform_tag": sysconfig.get_platform(),
            "ssl": ssl.OPENSSL_VERSION,
            "sqlite": sqlite3.sqlite_version,
        },
        "imports": imports,
        "checks": checks,
        "passed": all(checks.values()),
        "limitations": [
            "This verifies relocation and standard-library behavior only.",
            "Third-party Liana dependencies and model inference are separate staging gates.",
            (
                "The source archive identity is recorded separately and is not proven by this relocation audit."
                if not args.source_root
                else "The copied source root does not by itself prove the checksum of its original upstream archive."
            ),
        ],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
