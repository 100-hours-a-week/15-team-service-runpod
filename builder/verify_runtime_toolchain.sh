#!/usr/bin/env bash
set -euo pipefail

echo "[verify] checking C compiler availability..."
which cc
cc --version

echo "[verify] checking Python imports..."
python3 -c "import triton, torch; print('triton and torch import OK')"

echo "[verify] runtime toolchain check passed."
