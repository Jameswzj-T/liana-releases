#!/usr/bin/env python3
"""Verify local model files against the repository manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Mapping


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify(
    manifest_path: Path,
    group: str,
    roots: Mapping[str, Path],
) -> list[str]:
    manifest_path = Path(manifest_path)
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"无法读取模型清单 {manifest_path}: {exc}"]

    groups = manifest.get("groups", {})
    if group not in groups:
        return [f"模型清单中没有组: {group}"]

    group_config = groups[group]
    group_root = group_config.get("root")
    errors: list[str] = []
    for entry in group_config.get("files", []):
        relative_path = entry["path"]
        root_name = entry.get("root", group_root)
        if root_name not in roots:
            errors.append(
                f"[{group}] 未配置根路径 {root_name!r}: {relative_path}"
            )
            continue

        path = Path(roots[root_name]) / relative_path
        if not path.is_file():
            errors.append(f"[{group}] 缺少文件: {relative_path}（实际路径: {path}）")
            continue

        actual = sha256(path)
        expected = entry["sha256"].lower()
        if actual != expected:
            errors.append(
                f"[{group}] SHA-256 不匹配: {relative_path}"
                f"（期望: {expected}，实际: {actual}，路径: {path}）"
            )

    return errors


def _parse_args() -> argparse.Namespace:
    brain = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description="按清单校验 Liana 本地模型")
    parser.add_argument(
        "--manifest",
        type=Path,
        default=brain / "model-manifest.json",
        help="模型清单路径",
    )
    parser.add_argument("--group", required=True, help="待校验的模型组")
    parser.add_argument(
        "--root",
        type=Path,
        help="覆盖所选组的默认根目录（迁移校验使用）",
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    brain = Path(__file__).resolve().parents[1]
    roots = {
        "brain": brain,
        "brain_models": brain / "models",
        "app_support": Path.home() / "Library/Application Support/VoiceFlow",
    }

    if args.root is not None:
        try:
            manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
            root_name = manifest["groups"][args.group]["root"]
        except (OSError, json.JSONDecodeError, KeyError) as exc:
            print(f"✗ 无法确定组根路径: {exc}")
            return 2
        roots[root_name] = args.root

    errors = verify(args.manifest, args.group, roots)
    if errors:
        for error in errors:
            print(f"✗ {error}")
        return 1

    print(f"✓ 模型组 {args.group} 校验通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
