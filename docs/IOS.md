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
`//` as a comment), the fleet ingest token and the Supabase anon key. A build without these runs
fully offline and cannot turn on cloud sync.

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

Installing over an existing copy keeps its data, strap pairing and cloud enrollment.

## Turn on cloud sync

In the app, open **Settings → Nara account**, enter the enrollment code, and turn cloud sync on. The
app then uploads its strap history and shows the scores the backend computes. See
[ARCHITECTURE.md](ARCHITECTURE.md) for what happens next.

## Tests

```bash
xcodebuild test -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -derivedDataPath /tmp/nara-dd-mac -only-testing:StrandTests
```

Two caption tests, `SkinTempAbsoluteDisplayTests` and `SleepCarriedStampTests`, fail on a Mac set to
Pacific time because they render the previous day. The code they test has not changed since before
the Nara work.

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
