# Revclust Flutter SDK Example

This example mirrors the current mobile setup path for
`revclust_flutter_sdk`.

It shows the minimum integration shape:

- read the Revclust SDK key from `--dart-define`
- initialize `Revclust`
- register a small state snapshot provider
- capture one explicit sample invariant failure and watch upload events

The example is for Flutter mobile on `iOS` and `Android` only. It
does not enable automatic `Dio` or unhandled-exception hooks.
The sample payload uses privacy-safe reference values rather than raw customer
or order IDs.

## Run

From this directory:

```bash
flutter pub get
flutter run \
  --dart-define=REVCLUST_PROJECT_KEY=rpk_...
```

Replace the `rpk_...` value with the SDK key copied from the Revclust Apps
page.

Optional build metadata can be supplied by your existing build or CI system:

```bash
flutter run \
  --dart-define=REVCLUST_PROJECT_KEY=rpk_... \
  --dart-define=REVCLUST_APP_VERSION=1.4.2 \
  --dart-define=REVCLUST_BUILD=14207 \
  --dart-define=REVCLUST_GIT_SHA=abc1234
```

## What To Expect

1. Launch the app with valid `--dart-define` values.
2. Tap `Initialize SDK`.
3. Tap `Queue Sample Incident`.
4. Wait for the upload event log to show whether the incident was accepted,
   rejected, or blocked.
5. If the accepted event includes a viewer URL, open that incident in the
   Revclust viewer.

If the app starts without the required SDK key, it stays in an
offline example mode and explains what configuration is missing.
