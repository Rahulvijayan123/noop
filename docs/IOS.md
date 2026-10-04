# Build and install the iOS app

The iPhone app, its widgets and the Apple Watch app build from one Xcode project. The project file
is generated from `project.yml` by XcodeGen and is not committed.

## Requirements

- A Mac with Xcode 26 (currently built with 26.3)
- XcodeGen: `brew install xcodegen`
- An Apple Developer account, to sign builds for a physical iPhone

## One-time setup

Create the two gitignored config files from their examples, then generate the project:

```bash
cp Config/BundleIdSecrets.example.xcconfig Config/BundleIdSecrets.xcconfig
cp Config/CloudPushSecrets.example.xcconfig Config/CloudPushSecrets.xcconfig
xcodegen generate
```

In `Config/BundleIdSecrets.xcconfig`, set:

- `BUNDLE_ID_PREFIX`: the iPhone app's bundle ID is `<prefix>.noop`. The existing test install uses
  `com.rahulvijayan`. Changing the prefix installs a second app with none of the first one's data.
- `DEVELOPMENT_TEAM`: your Apple Developer Team ID.

In `Config/CloudPushSecrets.xcconfig`, set the upload endpoint
(`https:/$()/<project-ref>.supabase.co/functions/v1/push`; the `$()` keeps xcconfig from reading
`//` as a comment) and `NOOP_SUPABASE_PUBLISHABLE_KEY`, the project's `sb_publishable_…` key from
Supabase **Project Settings → API Keys**. The publishable key is public by design: it only tells
Supabase Auth which project a sign-up belongs to. There is no ingest token to configure, and a Supabase
secret key or `service_role` key must never go in this file because it would ship inside the app.
A build without these values runs fully offline and cannot sign in or turn on cloud sync.

`NOOP_ALLOW_LEGACY_ENROLLMENT` and `NOOP_LEGACY_FLEET_TOKEN` exist only for a migration build whose phones
still hold a credential from the old NARA enrollment-code flow and must keep uploading with it until the
person signs in. The app can no longer redeem a code. Leave both unset for testers; with them unset a
leftover credential is ignored and no shared token is ever sent.

Run `xcodegen generate` again whenever you add or remove source files, or edit `project.yml`.

## Build

```bash
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/nara-dd \
  -allowProvisioningUpdates build
```

The product is `/tmp/nara-dd/Build/Products/Debug-iphoneos/NOOP Staging.app`. The file name is
an internal product name; the home screen shows "Nara".

## Install on an iPhone

Connect and unlock the phone, then:

```bash
xcrun devicectl list devices                     # find the device identifier
D=<device-identifier>
xcrun devicectl device install app --device "$D" "/tmp/nara-dd/Build/Products/Debug-iphoneos/NOOP Staging.app"
xcrun devicectl device process launch --device "$D" --terminate-existing com.rahulvijayan.noop
```

Installing over an existing copy keeps its data, strap pairing and signed-in account.

## Create an account and turn on cloud sync

In the app, open **Settings → Nara account**, choose **Create account**, and enter an email address and a
password. Nara emails a one-time code; enter it to confirm the address and you are signed in. **Sign in**
and **Forgot password?** (which also emails a code) are on the same screen, and **Resend code** sends a
fresh code if the first did not arrive. Nothing is uploaded until a verified session exists.

After that the app links this phone to your account by itself: there is nothing to paste and no code to
redeem. Pair the strap as usual and the app confirms it against your account as soon as the strap reports
its serial number. Turn on **Sync with your account** and the app uploads its strap history and shows the
scores the backend computes. See [ARCHITECTURE.md](ARCHITECTURE.md) for what happens next.

Signing out stops uploads and removes this account's credential from the Keychain. Data that was already
recorded stays on the phone under that account, and keeps syncing to it the next time that account signs in.
It is never uploaded as someone else's. If you sign in as a different person, the phone's saved history
that belongs to the first account is left alone and is not mixed into the new account.

## Coach

The **Sana** tab (`StrandiOS/Coach/`) is the health assistant chat. Each launch starts a fresh conversation, the thinking indicator is a port of `thinking-orbs` (see [ATTRIBUTION.md](../ATTRIBUTION.md)), and `Strand/Coach/` holds the prompt, safety checks
and data tools it shares with the macOS app. It needs cloud sync to be on, because the model key lives
in the backend's `coach` function. Debug builds can open it directly with
`--demo-screen coach`; `--coach-prompt "<question>"` asks that question on launch and `--coach-focus` opens the keyboard.

## Tests

```bash
xcodebuild test -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -derivedDataPath /tmp/nara-dd-mac -only-testing:StrandTests
```

Two caption tests, `SkinTempAbsoluteDisplayTests` and `SleepCarriedStampTests`, fail on a Mac set to
Pacific time because they render the previous day. A third,
`IntradayWordingAndCoachTests.testMinuteBucketsAreDescribedAsMinuteBuckets`, also fails on a clean
checkout. The code these three test has not changed since before the account work.

`NaraEndToEndTests` skips itself unless a local Supabase stack is running. It signs up through real Supabase
Auth, reads the emailed code, and follows data all the way to a scored day. See
[supabase/tests/e2e/README.md](../supabase/tests/e2e/README.md) for how to start the stack and run it.

## Raw-data collector: activity labels

The Raw Data collector screen (WHOOP 5.0/MG) records the strap's 100 Hz six-axis IMU durably
during a session and exports `.imus` segments. Beyond moment/start/end/issue markers it now
takes interval labels (walking, running, sitting, standing, other movement) with a from/to
range; they export in `meta.json` (`activity_intervals`) and `events.jsonl` with
`user_confirmed` provenance. Sessions on unsupported device families now say so instead of
recording nothing, and a capture session re-arms itself after a relaunch or reconnect while it
is still active (and never while signed out or unpaired). Cloud sync packs recorded seconds
into `rawImuSession` objects through the object lane once a session's seconds are durable.

## Debugging on the phone

Copy the app's local database off the phone to inspect it with `sqlite3`:

```bash
for f in whoop.sqlite whoop.sqlite-wal whoop.sqlite-shm; do
  xcrun devicectl device copy from --device "$D" --domain-type appDataContainer \
    --domain-identifier com.rahulvijayan.noop \
    --source "Library/Application Support/OpenWhoop/$f" --destination "/tmp/$f"
done
sqlite3 /tmp/whoop.sqlite "select day, recovery, strain, avgHrv, restingHr, respRateBpm from dailyMetric order by day desc limit 7;"
```
