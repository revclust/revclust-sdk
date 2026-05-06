import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter_sdk/revclust_flutter_sdk.dart";
import "package:revclust_flutter_sdk/src/update_context/session_state_store.dart";
import "package:shared_preferences/shared_preferences.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test("initialize sets clean-shutdown sentinel to false for current session",
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      revclustCleanShutdownStorageKey: true,
      revclustLastCheckpointTimestampMsStorageKey:
          DateTime.now().millisecondsSinceEpoch - 1000,
    });
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());

    await sdk.initialize();

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(revclustCleanShutdownStorageKey), isFalse);
  });

  test("markCleanShutdown sets clean flag and checkpoint timestamp", () async {
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());
    final int beforeMs = DateTime.now().millisecondsSinceEpoch;

    await sdk.markCleanShutdown();

    final int afterMs = DateTime.now().millisecondsSinceEpoch;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int? checkpointMs = prefs.getInt(
      revclustLastCheckpointTimestampMsStorageKey,
    );
    expect(prefs.getBool(revclustCleanShutdownStorageKey), isTrue);
    expect(checkpointMs, isNotNull);
    expect(checkpointMs, inInclusiveRange(beforeMs, afterMs));
  });

  test("prior clean session emits no previous-session-unclean capture",
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      revclustCleanShutdownStorageKey: true,
      revclustLastCheckpointTimestampMsStorageKey:
          DateTime.now().millisecondsSinceEpoch - 1000,
    });
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());
    final List<CaptureEnvelope> emitted = <CaptureEnvelope>[];

    await sdk.initialize(onCapture: emitted.add);

    expect(emitted, isEmpty);
  });

  test("prior unclean false emits one capture with last checkpoint age",
      () async {
    final int checkpointMs = DateTime.now().millisecondsSinceEpoch - 500;
    SharedPreferences.setMockInitialValues(<String, Object>{
      revclustCleanShutdownStorageKey: false,
      revclustLastCheckpointTimestampMsStorageKey: checkpointMs,
    });
    final RevclustSdk sdk = RevclustSdk(
      config: SdkConfig(),
      monotonicClockMs: () => 123,
    );
    final List<CaptureEnvelope> emitted = <CaptureEnvelope>[];

    await sdk.initialize(onCapture: emitted.add);

    expect(emitted, hasLength(1));
    final CaptureEnvelope envelope = emitted.single;
    expect(envelope.trigger.type, "previous_session_unclean_exit");
    expect(envelope.trigger.reason, "previous session ended uncleanly");
    expect(envelope.trigger.signature, isNull);
    expect(envelope.trigger.expected, isNull);
    expect(envelope.trigger.observed, isA<Map<String, Object?>>());

    final Map<String, Object?> observed =
        envelope.trigger.observed! as Map<String, Object?>;
    expect(observed.keys, <String>["last_checkpoint_age_ms"]);
    expect(observed["last_checkpoint_age_ms"], isA<int>());
    expect(observed["last_checkpoint_age_ms"] as int, greaterThanOrEqualTo(0));
  });

  test(
      "absent prior clean flag is treated as unclean only when checkpoint exists",
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      revclustLastCheckpointTimestampMsStorageKey:
          DateTime.now().millisecondsSinceEpoch - 500,
    });
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());
    final List<CaptureEnvelope> emitted = <CaptureEnvelope>[];

    await sdk.initialize(onCapture: emitted.add);

    expect(emitted, hasLength(1));
    expect(emitted.single.trigger.type, "previous_session_unclean_exit");
  });

  test(
      "initialize-related paths emit unclean-exit capture at most once per session",
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      revclustCleanShutdownStorageKey: false,
      revclustLastCheckpointTimestampMsStorageKey:
          DateTime.now().millisecondsSinceEpoch - 1000,
    });
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());
    final List<CaptureEnvelope> emitted = <CaptureEnvelope>[];

    await sdk.initialize(onCapture: emitted.add);
    await sdk.initialize(onCapture: emitted.add);

    expect(emitted, hasLength(1));
  });

  test("missing checkpoint timestamp emits no unclean-exit capture", () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      revclustCleanShutdownStorageKey: false,
    });
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());
    final List<CaptureEnvelope> emitted = <CaptureEnvelope>[];

    await sdk.initialize(onCapture: emitted.add);

    expect(emitted, isEmpty);
  });
}
