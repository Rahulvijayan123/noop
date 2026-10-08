#!/usr/bin/env bash
# iPhone Settings against the disposable stack (stack.sh up first). Builds the app pointed at the stack, then on
# a simulator:
#   1. opens every Settings row and checks it lands on its own page,
#   2. changes local preferences, relaunches, and checks they come back,
#   3. creates an account in Settings and edits the profile and the account-wide preferences (phase 1), checks
#      the profiles and user_settings rows in Postgres, uninstalls the app, then signs in on the fresh install
#      and checks Settings shows what was saved (phase 2).
# The account is a throwaway on the local stack; nothing here touches a hosted project.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
WORK="${NARA_E2E_DIR:-$HOME/.cache/nara-auth-e2e}"
SIM="${NARA_UI_SIMULATOR:-iPhone 17 Pro}"
DERIVED="${NARA_UI_DERIVED:-/tmp/dd-settings-ui}"

if [ ! -f "$WORK/run/stack.env" ]; then
  echo "no stack: run $HERE/stack.sh up first" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
source "$WORK/run/stack.env"
set +a

UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["name"] == name:
            print(d["udid"]); raise SystemExit
' "$SIM")"
[ -n "$UDID" ] || { echo "no simulator named $SIM" >&2; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null || true

EMAIL="settings-ui-$(date +%s)@example.test"
PASSWORD="ui-$(openssl rand -hex 8)"
NAME="Settings UI $(openssl rand -hex 2)"
export TEST_RUNNER_NARA_E2E_GATEWAY="$NARA_E2E_GATEWAY"
export TEST_RUNNER_NARA_UI_EMAIL="$EMAIL"
export TEST_RUNNER_NARA_UI_PASSWORD="$PASSWORD"
export TEST_RUNNER_NARA_UI_NAME="$NAME"

cd "$REPO"
DEST="platform=iOS Simulator,id=$UDID"
xcodebuild build-for-testing -project Strand.xcodeproj -scheme NOOPiOSUITests -destination "$DEST" \
  -derivedDataPath "$DERIVED" \
  NOOP_PUSH_ENDPOINT="$NARA_E2E_GATEWAY/functions/v1/push" \
  NOOP_SUPABASE_PUBLISHABLE_KEY="$NARA_E2E_PUBLISHABLE_KEY" NOOP_SUPABASE_ANON_KEY= \
  NOOP_FINAL_HOSTED_COMPUTE=NO NOOP_SENTRY_DSN= >/dev/null

APP="$(find "$DERIVED/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name '*.app' ! -name '*UITests*' | head -1)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")"

run() {
  xcodebuild test-without-building -project Strand.xcodeproj -scheme NOOPiOSUITests -destination "$DEST" \
    -derivedDataPath "$DERIVED" "-only-testing:NOOPiOSUITests/SettingsUITests/$1"
}
fresh_install() { xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true; }

fresh_install
run testEveryRowOpensThePageItNames
run testLocalPreferencesComeBackAfterARelaunch

fresh_install
run testAccountPhase1SaveProfileToSupabase
ROW="$(psql "$NARA_E2E_DATABASE_URL" -Atc "select p.display_name || '|' || coalesce(p.sex_model, '') || '|' || coalesce(p.height_cm::text, '')
  from public.profiles p join auth.users u on u.id = p.id where u.email = '$EMAIL'")"
echo "profiles row: $ROW"
[ "$ROW" = "$NAME|female|182" ] || { echo "the profile edited in Settings did not reach Supabase" >&2; exit 1; }
PREFS="$(psql "$NARA_E2E_DATABASE_URL" -Atc "select s.units || '|' || coalesce(s.extra_settings->'nara'->>'batteryAlerts', '') || '|' || coalesce(s.extra_settings->'nara'->>'hapticLiftRest', '')
  from public.user_settings s join auth.users u on u.id = s.user_id where u.email = '$EMAIL'")"
echo "user_settings row: $PREFS"
[ "$PREFS" = "imperial|false|false" ] || { echo "the preferences changed in Settings did not reach Supabase" >&2; exit 1; }

fresh_install
run testAccountPhase2RestoreProfileFromSupabase
echo "settings UI: all phases passed"
