import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter_sdk/src/internal/revclust_internal.dart";
import "package:revclust_flutter_sdk/src/update_context/session_state_store.dart";
import "package:shared_preferences/shared_preferences.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test("first run with no stored version returns fresh install snapshot",
      () async {
    final RevclustSdk sdk = RevclustSdk(
      config: SdkConfig(appVersion: "1.0.0"),
    );

    final UpdateContextSnapshot snapshot = await sdk.initialize();

    expect(snapshot.isFirstRunAfterUpdate, isFalse);
    expect(snapshot.prevAppVersion, isNull);
    expect(
      snapshot.installType,
      UpdateContextSnapshot.installTypeFreshInstall,
    );
    expect(sdk.updateContextSnapshot, snapshot);

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(revclustLastSeenAppVersionStorageKey),
      "1.0.0",
    );
  });

  test("same version relaunch returns unknown install type", () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      revclustLastSeenAppVersionStorageKey: "2.1.0",
    });
    final RevclustSdk sdk = RevclustSdk(
      config: SdkConfig(appVersion: "2.1.0"),
    );

    final UpdateContextSnapshot snapshot = await sdk.initialize();

    expect(snapshot.isFirstRunAfterUpdate, isFalse);
    expect(snapshot.prevAppVersion, isNull);
    expect(snapshot.installType, UpdateContextSnapshot.installTypeUnknown);

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(revclustLastSeenAppVersionStorageKey),
      "2.1.0",
    );
  });

  test("updated version returns update snapshot with previous version",
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      revclustLastSeenAppVersionStorageKey: "2.1.0",
    });
    final RevclustSdk sdk = RevclustSdk(
      config: SdkConfig(appVersion: "2.2.0"),
    );

    final UpdateContextSnapshot snapshot = await sdk.initialize();

    expect(snapshot.isFirstRunAfterUpdate, isTrue);
    expect(snapshot.prevAppVersion, "2.1.0");
    expect(snapshot.installType, UpdateContextSnapshot.installTypeUpdate);

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(revclustLastSeenAppVersionStorageKey),
      "2.2.0",
    );
  });

  test("missing app version input returns unknown without persistence writes",
      () async {
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());

    final UpdateContextSnapshot snapshot = await sdk.initialize();

    expect(snapshot.isFirstRunAfterUpdate, isFalse);
    expect(snapshot.prevAppVersion, isNull);
    expect(snapshot.installType, UpdateContextSnapshot.installTypeUnknown);

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.containsKey(revclustLastSeenAppVersionStorageKey),
      isFalse,
    );
  });

  test("initializeUpdateContext does not mutate session-exit state", () async {
    final int checkpointMs = DateTime.now().millisecondsSinceEpoch - 500;
    SharedPreferences.setMockInitialValues(<String, Object>{
      revclustCleanShutdownStorageKey: true,
      revclustLastCheckpointTimestampMsStorageKey: checkpointMs,
    });
    final RevclustSdk sdk = RevclustSdk(
      config: SdkConfig(appVersion: "1.0.0"),
    );

    final UpdateContextSnapshot snapshot = await sdk.initializeUpdateContext();

    expect(snapshot.installType, UpdateContextSnapshot.installTypeFreshInstall);

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(revclustLastSeenAppVersionStorageKey),
      "1.0.0",
    );
    expect(prefs.getBool(revclustCleanShutdownStorageKey), isTrue);
    expect(
      prefs.getInt(revclustLastCheckpointTimestampMsStorageKey),
      checkpointMs,
    );
  });

  test("persisted app version is written and updated using init override",
      () async {
    final RevclustSdk firstSdk = RevclustSdk(config: SdkConfig());
    await firstSdk.initialize(appVersion: " 3.0.0 ");

    final SharedPreferences firstPrefs = await SharedPreferences.getInstance();
    expect(
      firstPrefs.getString(revclustLastSeenAppVersionStorageKey),
      "3.0.0",
    );

    final RevclustSdk secondSdk = RevclustSdk(config: SdkConfig());
    await secondSdk.initialize(appVersion: "3.1.0");

    final SharedPreferences secondPrefs = await SharedPreferences.getInstance();
    expect(
      secondPrefs.getString(revclustLastSeenAppVersionStorageKey),
      "3.1.0",
    );
  });

  test("installType values remain schema-aligned", () {
    expect(UpdateContextSnapshot.installTypeFreshInstall, "fresh_install");
    expect(UpdateContextSnapshot.installTypeUpdate, "update");
    expect(UpdateContextSnapshot.installTypeUnknown, "unknown");
    expect(
      UpdateContextSnapshot.allowedInstallTypes,
      <String>{"fresh_install", "update", "unknown"},
    );
  });

  test("provided app version is validated at runtime", () async {
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());
    expect(
      () => sdk.initialize(appVersion: "   "),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => sdk.initializeUpdateContext(appVersion: "   "),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => SdkConfig(appVersion: "   "),
      throwsA(isA<ArgumentError>()),
    );
  });
}
