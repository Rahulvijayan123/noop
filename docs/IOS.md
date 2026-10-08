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

Set `NOOP_FINAL_HOSTED_COMPUTE = YES` in the same file for any build you give to someone else. Cloud sync is
then the only mode: the account sheet cannot be skipped, there is no sync switch, and neither a stored
preference nor a developer endpoint override can turn sync off or point it at another server. With the
default `NO`, cloud stays an opt-in switch, which is what a developer build wants.

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

## Create an account

In a build with `NOOP_FINAL_HOSTED_COMPUTE = YES` the account sheet opens by itself once onboarding and the
terms are done, and it cannot be dismissed. In any other build, open **Settings → Nara account**. Choose
**Create account** and enter an email address and a password. Nara emails an eight-digit one-time code;
enter it to confirm the address and you are signed in. **Sign in** and **Forgot password?** (which also
emails a code) are on the same screen, and **Resend code** sends a fresh code if the first did not arrive.
Nothing is uploaded until a verified session exists.

After that the app links this phone to your account by itself: there is nothing to paste and no code to
redeem. Pair the strap as usual and the app confirms it against your account as soon as the strap reports
its serial number. In a hosted-compute build it then uploads the strap history and shows the scores the
backend computes, with no switch to find. In any other build, turn on **Sync with your account** first.
See [ARCHITECTURE.md](ARCHITECTURE.md) for what happens next.

Signing out stops uploads and removes this account's credential from the Keychain. Data that was already
recorded stays on the phone under that account, and keeps syncing to it the next time that account signs in.
It is never uploaded as someone else's. If you sign in as a different person, the phone's saved history
that belongs to the first account is left alone and is not mixed into the new account.

## Coach

The **Sana** tab (`StrandiOS/Coach/`) is the health assistant chat. Each launch starts a fresh conversation, the thinking indicator is a port of `thinking-orbs` (see [ATTRIBUTION.md](../ATTRIBUTION.md)), and `Strand/Coach/` holds the prompt, safety checks
and data tools it shares with the macOS app. It needs cloud sync to be on, because the model key lives
in the backend's `coach` function. Debug builds can open it directly with
`--demo-screen coach`; `--coach-prompt "<question>"` asks that question on launch and `--coach-focus` opens the keyboard.

## Activity context and stand reminders

What the wearer was doing is decoded from the strap's own streams (see
[CURRENT_ALGORITHMS.md](CURRENT_ALGORITHMS.md), sections 9 and 10) and kept on the phone, so history,
the coach and the stand reminder all read the same record.

- **When it is written.** `ActivityContextCoordinator` (`Strand/Data/`) runs after each completed
  backfill and on the 30-minute cadence, in the background, one pass at a time. It never delays the widget
  or Health writes. Today and the recent days are checked first; older days of the last 120 fill in over a
  few passes (at most two old days each). A closed day is written once and an up-to-date day is not
  rewritten. Everything stored is derived from the raw streams and can be rebuilt; clearing a strap's data
  clears it too.
- **Where it lives.** `activityContextInterval` (one row per stretch of constant behaviour, with the class,
  its confidence and the heart rate, HRV, respiratory rate, steps and cadence measured inside it) and the
  `activityContextDay` ledger, in `whoop.sqlite`. The raw streams are not copied: the `*Ctx` views
  (`hrSampleCtx`, `rrIntervalCtx`, `spo2SampleCtx`, ...) join each sample to its interval by timestamp,
  and a sample outside any interval shows NULL context.

```bash
sqlite3 /tmp/whoop.sqlite "select ctxClass, count(*) as samples, round(avg(bpm)) as avg_bpm
  from hrSampleCtx where ts > strftime('%s','now','-1 day') group by ctxClass order by samples desc;"
sqlite3 /tmp/whoop.sqlite "select day, activityClass, seconds from activityContextDayClass order by day desc, seconds desc limit 20;"
```

- **Coach.** `get_activity_context` (always available) returns the classes, durations, confidence and the
  measurements of each for a window, and says plainly when nothing was saved.
- **Stand reminder.** Turn it on under Automations; the threshold stepper is the length of the rolling
  window (50 minutes by default). It is judged after each completed backfill, so a reminder can arrive up
  to one offload late: about 15 minutes at the default cadence, about a minute with the 5.0/MG "fresh
  data" cadence in cloud mode while Nara is open (it syncs every 15 minutes in the background), and 45 to 60 minutes while the strap is low on battery or Low refresh is on. The shareable strap log records why it did or did not fire, for
  example `Stand reminder: movedEnough (50-min window: 72 s standing or moving, 98% observed, 90% seated)`.
  The old gravity-only nudge in `BLEManager` is switched off (`legacyInactivityNudgeEnabled`).

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
