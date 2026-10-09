#!/bin/bash
# Package one git revision as a release (deploy/README.md, "Build + release").
# The work is in package_release.py beside this script; see its docstring for the options.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 "$SCRIPT_DIR/package_release.py" "$@"
