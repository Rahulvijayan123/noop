#!/usr/bin/env bash
# Screenshot one page of a DEBUG simulator build from top to bottom.
#
#   tour.sh <udid> <bundle-id> <out-dir> <name> [app launch arguments...]
#
# Launches the app with `--demo-seed --demo-no-prompts --demo-tour` plus the given arguments (for example `--demo-tab 3`,
# `--demo-push metric:hrv`, `--demo-days 3`, `--demo-screen settings`) and saves <out-dir>/<name>-<n>.png for
# every screenful the app scrolls through (StrandiOS/App/DemoTourHarness.swift is the app side).
#
# With SHOT_AFTER=<seconds> it skips the tour and takes one screenshot that many seconds after launch, which
# with `--demo-load-delay` captures a screen's loading state.
#
# Needs DEVELOPER_DIR pointing at a full Xcode. The app must already be installed; a fresh install is how a
# different `--demo-days` density is seeded, because the seed only runs into an empty store.
set -euo pipefail
udid=$1 bundle=$2 out=$3 name=$4
shift 4
mkdir -p "$out"

if [[ -n "${SHOT_AFTER:-}" ]]; then
  xcrun simctl launch --terminate-running-process "$udid" "$bundle" --demo-seed --demo-no-prompts "$@" >/dev/null
  sleep "$SHOT_AFTER"
  xcrun simctl io "$udid" screenshot "$out/$name.png" >/dev/null 2>&1
  echo "$out/$name.png"
  exit 0
fi

container=$(xcrun simctl get_app_container "$udid" "$bundle" data)
dir="$container/Documents/demo-tour"
rm -rf "$dir"
xcrun simctl launch --terminate-running-process "$udid" "$bundle" --demo-seed --demo-no-prompts --demo-tour "$@" >/dev/null

step=0
deadline=$((SECONDS + ${TOUR_TIMEOUT:-90}))
while (( SECONDS < deadline )); do
  if [[ -e "$dir/$step.ready" ]]; then
    xcrun simctl io "$udid" screenshot "$out/$name-$step.png" >/dev/null 2>&1
    echo "$out/$name-$step.png"
    touch "$dir/$step.done"
    step=$((step + 1))
    deadline=$((SECONDS + 30))
  elif [[ -e "$dir/finished" ]]; then
    exit 0
  else
    sleep 0.2
  fi
done
echo "tour.sh: timed out at step $step" >&2
exit 1
