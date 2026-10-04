#!/bin/bash
# Run the app-level end-to-end suite (StrandTests/NaraEndToEndTests) against a stack started with stack.sh.
#
#   run_swift.sh [xcodebuild arguments...]
#
# The stack's environment is handed to the hosted test process through xcodebuild's TEST_RUNNER_ prefix.
# Without a stack the suite skips itself.
#
#   NARA_E2E_APP_DIR   directory containing Strand.xcodeproj (default: this checkout). Hosted tests that read
#                      their own sources hang on a removable-volume permission prompt when the checkout sits
#                      on an external drive; run them from a copy on the internal disk if that applies to you.
#   NARA_E2E_DERIVED   derived data path (default /tmp/dd-e2e)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
WORK="${NARA_E2E_DIR:-$HOME/.cache/nara-auth-e2e}"

if [ ! -f "$WORK/run/stack.env" ]; then
  echo "no stack: run $HERE/stack.sh up first" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
source "$WORK/run/stack.env"
set +a

for name in NARA_E2E_GATEWAY NARA_E2E_PUBLISHABLE_KEY NARA_E2E_SECRET_KEY; do
  export "TEST_RUNNER_$name=${!name}"
done

cd "${NARA_E2E_APP_DIR:-$REPO}"
exec xcodebuild test -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${NARA_E2E_DERIVED:-/tmp/dd-e2e}" CODE_SIGNING_ALLOWED=NO \
  -only-testing:StrandTests/NaraEndToEndTests "$@"
