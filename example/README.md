# Revclust Flutter SDK Example

This example mirrors the current managed mobile pilot onboarding path for
`revclust_flutter_sdk`.

It shows the minimum integration shape:

- read the Revclust project key and environment from `--dart-define`
- initialize `Revclust`
- register a small reviewed state snapshot provider
- trigger one explicit sample incident and watch upload events

The default quickstart is for Flutter mobile on `iOS` and `Android` only. It
does not enable automatic `Dio` or unhandled-exception hooks.
The sample payload uses privacy-safe reference values rather than raw customer
or order IDs.

## Run

From this directory:

```bash
flutter pub get
flutter run \
  --dart-define=REVCLUST_PROJECT_KEY=rpk_... \
  --dart-define=REVCLUST_ENVIRONMENT=staging
```

Replace the `rpk_...` key and environment with the values provisioned for your
team during onboarding.

## What To Expect

1. Launch the app with valid `--dart-define` values.
2. Tap `Initialize SDK`.
3. Tap `Queue Sample Incident`.
4. Wait for the upload event log to show whether the incident was accepted,
   rejected, or blocked.
5. If the accepted event includes a viewer URL, open that incident in the
   Revclust viewer.

If the app starts without the required `--dart-define` values, it stays in an
offline quickstart mode and explains what configuration is missing.
