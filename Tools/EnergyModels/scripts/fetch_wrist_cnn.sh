#!/usr/bin/env bash
# Fetch, verify and convert the pinned wrist-CNN weights (never committed; see
# artifacts/wrist_cnn/NOTICE.md and artifacts/wrist_cnn/manifest.json).
#
#   scripts/fetch_wrist_cnn.sh             download if needed, verify, convert, verify again
#   scripts/fetch_wrist_cnn.sh --check     verify the converted files on disk (no network, no h5py)
#   scripts/fetch_wrist_cnn.sh --offline   reuse cached upstream .h5 files, never touch the network
#   PYTHON=/path/to/python scripts/fetch_wrist_cnn.sh
#
# Exit status: 0 ok, 1 --check found a missing/mismatching file, 2 sha256 mismatch (REFUSING),
# 3 any other error. Idempotent: verified artifacts are left untouched.
#
# Converting needs numpy and h5py. If the chosen interpreter lacks them, a throwaway virtualenv with
# the pins from requirements-cnn-convert.txt is created in $TMPDIR and removed on exit; the
# application environment is never modified. NARA_WRIST_CNN_DIR overrides the artifact directory.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

offline=0
check_only=0
print_digests=0
for arg in "$@"; do
  case "$arg" in
    --offline) offline=1 ;;
    --check | -h | --help) check_only=1 ;;
    --print-npz-digests) print_digests=1 ;;
  esac
done

py="${PYTHON:-}"
if [[ -z "$py" ]]; then
  first=""
  for cand in python3.11 python3.12 python3.13 python3.10 python3 python; do
    command -v "$cand" >/dev/null 2>&1 || continue
    found="$(command -v "$cand")"
    first="${first:-$found}"
    if "$found" -c "import numpy" >/dev/null 2>&1; then
      py="$found"
      break
    fi
  done
  py="${py:-$first}"
fi
if [[ -z "$py" ]]; then
  echo "error: no python interpreter found; set PYTHON=/path/to/python" >&2
  exit 3
fi

# numpy 2.2.6 (pinned) needs Python >= 3.10, so build the throwaway environment from a new enough one.
venv_base=""
for cand in python3.11 python3.12 python3.13 python3.10; do
  if command -v "$cand" >/dev/null 2>&1; then
    venv_base="$(command -v "$cand")"
    break
  fi
done
venv_base="${venv_base:-$py}"

tmp_venv=""
cleanup() {
  if [[ -n "$tmp_venv" ]]; then
    rm -rf "$tmp_venv"
  fi
}
trap cleanup EXIT

ensure_modules() {
  local mods="$1"
  if "$py" -c "import $mods" >/dev/null 2>&1; then
    return 0
  fi
  if [[ -n "${PYTHON:-}" ]]; then
    echo "error: $PYTHON cannot import: $mods (see requirements-cnn-convert.txt)" >&2
    exit 3
  fi
  if [[ $offline -eq 1 ]]; then
    echo "error: missing python modules ($mods) and --offline forbids installing them" >&2
    exit 3
  fi
  tmp_venv="$(mktemp -d "${TMPDIR:-/tmp}/wrist-cnn-convert.XXXXXX")"
  echo "missing python modules ($mods): creating a throwaway environment in $tmp_venv" >&2
  "$venv_base" -m venv "$tmp_venv"
  "$tmp_venv/bin/python" -m pip install --quiet --disable-pip-version-check -r requirements-cnn-convert.txt
  py="$tmp_venv/bin/python"
}

fetch() { "$py" -m energy_models.wrist_cnn.fetch "$@"; }

run() {
  set +e
  fetch "$@"
  local status=$?
  set -e
  exit "$status"
}

if [[ $check_only -eq 1 ]]; then
  ensure_modules "numpy"
  run "$@"
fi

ensure_modules "numpy"
needs_h5py=1
if [[ $print_digests -eq 0 ]] && fetch --check >/dev/null 2>&1; then
  needs_h5py=0
fi
if [[ $needs_h5py -eq 1 ]]; then
  ensure_modules "numpy, h5py"
fi
run "$@"
