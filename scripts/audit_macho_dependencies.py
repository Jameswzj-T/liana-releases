#!/usr/bin/env python3
"""Audit every Mach-O under a staging tree for build-machine path leakage."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess


MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}
SYSTEM_PREFIXES = ("/System/Library/", "/usr/lib/")
LOADER_PREFIXES = ("@rpath/", "@loader_path/", "@executable_path/")


def is_macho(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            return handle.read(4) in MACHO_MAGICS
    except OSError:
        return False


def run_otool(*args: str) -> tuple[int, str]:
    completed = subprocess.run(
        ["/usr/bin/otool", *args],
        check=False,
        capture_output=True,
        text=True,
    )
    return completed.returncode, completed.stdout + completed.stderr


def allowed_reference(reference: str, root: Path) -> bool:
    if reference in ("@rpath", "@loader_path", "@executable_path"):
        return True
    if reference.startswith(SYSTEM_PREFIXES + LOADER_PREFIXES):
        return True
    if not reference.startswith("/"):
        return False
    try:
        Path(reference).resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def parse_dependencies(output: str) -> list[str]:
    dependencies: list[str] = []
    for line in output.splitlines()[1:]:
        match = re.match(r"\s*(\S+)\s+\(compatibility version", line)
        if match:
            dependencies.append(match.group(1))
    return dependencies


def parse_rpaths(output: str) -> list[str]:
    lines = output.splitlines()
    paths: list[str] = []
    for index, line in enumerate(lines):
        if line.strip() != "cmd LC_RPATH":
            continue
        for candidate in lines[index + 1 : index + 5]:
            match = re.match(r"\s*path\s+(\S+)\s+\(offset", candidate)
            if match:
                paths.append(match.group(1))
                break
    return paths


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    root = args.root.resolve()
    files = sorted(path for path in root.rglob("*") if path.is_file() and is_macho(path))
    records: list[dict[str, object]] = []
    external_dependencies: list[dict[str, str]] = []
    external_install_ids: list[dict[str, str]] = []
    external_rpaths: list[dict[str, str]] = []
    tool_errors: list[dict[str, str]] = []

    for path in files:
        relative = path.relative_to(root).as_posix()
        status_l, output_l = run_otool("-L", str(path))
        if status_l != 0:
            tool_errors.append({"path": relative, "tool": "otool -L", "output": output_l.strip()})
            continue
        status_d, output_d = run_otool("-D", str(path))
        install_ids: list[str] = []
        if status_d == 0:
            install_ids = [line.strip() for line in output_d.splitlines()[1:] if line.strip()]
            for install_id in install_ids:
                if not allowed_reference(install_id, root):
                    external_install_ids.append({"path": relative, "reference": install_id})

        # For dylibs/bundles, otool -L includes the file's own install ID in the
        # same list as load dependencies. An odd own ID is metadata residue; it
        # is not an external load until another binary actually references it.
        dependencies = [item for item in parse_dependencies(output_l) if item not in install_ids]
        for dependency in dependencies:
            if not allowed_reference(dependency, root):
                external_dependencies.append({"path": relative, "reference": dependency})

        status_load, output_load = run_otool("-l", str(path))
        rpaths: list[str] = []
        if status_load != 0:
            tool_errors.append({"path": relative, "tool": "otool -l", "output": output_load.strip()})
        else:
            rpaths = parse_rpaths(output_load)
            for rpath in rpaths:
                if not allowed_reference(rpath, root):
                    external_rpaths.append({"path": relative, "reference": rpath})

        records.append(
            {
                "path": relative,
                "bytes": path.stat().st_size,
                "dependencies": dependencies,
                "install_ids": install_ids,
                "rpaths": rpaths,
            }
        )

    checks = {
        "found_macho_files": bool(files),
        "otool_succeeded_for_all": not tool_errors,
        "no_external_dependencies": not external_dependencies,
        "no_external_rpaths": not external_rpaths,
    }
    report = {
        "schema_version": 1,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "root": str(root),
        "macho_count": len(files),
        "macho_bytes": sum(path.stat().st_size for path in files),
        "checks": checks,
        "external_dependencies": external_dependencies,
        "external_install_ids": external_install_ids,
        "external_rpaths": external_rpaths,
        "tool_errors": tool_errors,
        "files": records,
        "passed": all(checks.values()),
        "limitations": [
            "This validates recorded load commands, not code signing or notarization.",
            "@rpath references still require runtime import or launch smoke tests to prove resolution.",
            "External own install IDs are reported as metadata advisories, not load failures.",
        ],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Mach-O files: {len(files)}")
    print(f"External dependencies: {len(external_dependencies)}")
    print(f"External install IDs: {len(external_install_ids)}")
    print(f"External rpaths: {len(external_rpaths)}")
    print(f"otool errors: {len(tool_errors)}")
    print("PASS" if report["passed"] else "FAIL")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
