#!/usr/bin/env bash
# fetch_artifacts.sh — download pinned HART checkpoint (+ optional WISDM archive)
# and verify sha256 digests (model manifest + fetch_artifacts.py share the pins).
#
# Usage:
#   ./fetch_artifacts.sh --checkpoint-dir ./checkpoint
#   ./fetch_artifacts.sh --checkpoint-dir ./checkpoint --wisdm /tmp/wisdm.zip
#
# Policy: weights are NEVER committed to git; this script fetches them at
# deploy/train time. WISDM-19 is CC BY 4.0 (attribution in README/NOTICE).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="${PYTHON:-python3}"
if [ -x "$HERE/.venv/bin/python" ]; then
  PY="$HERE/.venv/bin/python"
fi
export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"
exec "$PY" -m activity_context.fetch_artifacts "$@"
