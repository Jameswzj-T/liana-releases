#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
case "${1:-build}" in
  build)
    (cd mac && swift build -c release)
    ;;
  check)
    checker="${LIANA_CHECK_PYTHON:-$PWD/brain/.venv/bin/python}"
    if [[ ! -x "$checker" ]]; then
      checker="$(command -v python3.12 || true)"
    fi
    if [[ -z "$checker" ]]; then
      echo 'Python 3.12 is required. Create brain/.venv or set LIANA_CHECK_PYTHON.' >&2
      exit 1
    fi
    "$checker" -B -S -c 'import sys; assert sys.version_info[:2] == (3, 12), "Use Python 3.12"'
    "$checker" -B -S scripts/check_source.py
    PYTHONPATH="$PWD/brain" "$checker" -B -S -m unittest discover -s brain/tests -v
    (cd mac && swift test)
    ;;
  *)
    echo 'Usage: bash build.sh [build|check]' >&2
    exit 2
    ;;
esac
