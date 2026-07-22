import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter/src/internal/revclust_internal.dart";

final RegExp _uuidV4Pattern = RegExp(
  r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
  caseSensitive: false,
);

void main() {
  test("captureNow returns typed envelope with UUID and trigger fields", () {
    final RevclustSdk sdk = RevclustSdk(
      config: SdkConfig(),
      monotonicClockMs: () => 5000,
    );
    sdk.recordUiIntent(tMonoMs: 4500, name: "checkout.submit");

    final CaptureEnvelope envelope = sdk.captureNow(
      reason: "checkout mismatch",
      expected: const <String, Object?>{"total": 1200},
      observed: const <String, Object?>{"total": 1199},
      signature: "checkout.total_mismatch.v1",
    );

    expect(envelope.captureId, isNotEmpty);
    expect(envelope.captureId, matches(_uuidV4Pattern));
    expect(envelope.trigger.type, "programmatic");
    expect(envelope.trigger.reason, "checkout mismatch");
    expect(envelope.trigger.expected, const <String, Object?>{"total": 1200});
    expect(envelope.trigger.observed, const <String, Object?>{"total": 1199});
    expect(envelope.trigger.signature, "checkout.total_mismatch.v1");
    expect(envelope.timeline, isNotEmpty);
  });

  test("capture timestamps are plausible and monotonic source is respected",
      () {
    final RevclustSdk sdk = RevclustSdk(
      config: SdkConfig(),
      monotonicClockMs: _sequenceClock(<int>[12, 30]),
    );

    final int beforeUtcMs = DateTime.now().millisecondsSinceEpoch;
    final CaptureEnvelope first = sdk.captureNow(reason: "first");
    final int afterUtcMs = DateTime.now().millisecondsSinceEpoch;
    final CaptureEnvelope second = sdk.captureNow(reason: "second");

    expect(first.triggerUtcMs, inInclusiveRange(beforeUtcMs, afterUtcMs));
    expect(first.triggerMonoMs, greaterThanOrEqualTo(0));
    expect(second.triggerMonoMs, greaterThan(first.triggerMonoMs));
  });

  test(
      "captureNow slices only pre-window timeline events in deterministic order",
      () {
    final RevclustSdk sdk = RevclustSdk(
      config: SdkConfig(bufferWindowSec: 1),
      monotonicClockMs: () => 5000,
    );

    sdk.recordUiIntent(tMonoMs: 3999, name: "too_old");
    sdk.recordUiIntent(tMonoMs: 4000, name: "window_start");
    sdk.recordLifecycleForeground(tMonoMs: 4500);
    sdk.recordUiIntent(tMonoMs: 4500, name: "same_time");
    sdk.recordUiIntent(tMonoMs: 4999, name: "recent");
    sdk.recordUiIntent(tMonoMs: 5000, name: "at_trigger");
    sdk.recordUiIntent(tMonoMs: 5001, name: "future");

    final CaptureEnvelope envelope = sdk.captureNow(reason: "slice-test");

    expect(
      envelope.timeline.map((TimelineEvent event) => event.tMonoMs).toList(),
      <int>[4000, 4500, 4500, 4999, 5000],
    );
    expect(
      envelope.timeline.map(_eventLabel).toList(),
      <String>[
        "ui:window_start",
        "lifecycle.foreground",
        "ui:same_time",
        "ui:recent",
        "ui:at_trigger",
      ],
    );
    expect(
      envelope.timeline.every(
        (TimelineEvent event) =>
            event.tMonoMs <= envelope.triggerMonoMs &&
            envelope.triggerMonoMs - event.tMonoMs <= 1000,
      ),
      isTrue,
    );
  });

  test("trigger APIs map to expected trigger types", () {
    final RevclustSdk sdk = RevclustSdk(
      config: SdkConfig(),
      monotonicClockMs: () => 0,
    );

    final CaptureEnvelope programmatic = sdk.captureNow(reason: "prog");
    final CaptureEnvelope manual = sdk.captureManual(reason: "manual");

    expect(programmatic.trigger.type, "programmatic");
    expect(manual.trigger.type, "manual");
  });

  test("captureNow starts runtime-condition capture immediately", () async {
    final _SequencedRuntimeConditionsProvider provider =
        _SequencedRuntimeConditionsProvider(
      <RuntimeConditionsSnapshot>[
        const RuntimeConditionsSnapshot(
          deviceModel: "Pixel 9 Pro",
          osVersion: "Android 16",
          networkType: "wifi",
        ),
        const RuntimeConditionsSnapshot(
          deviceModel: "iPhone15,4",
          osVersion: "iOS 18.2",
          networkType: "cellular",
        ),
      ],
    );
    final RevclustSdk sdk = RevclustSdk(
      config: SdkConfig(),
      monotonicClockMs: () => 0,
      runtimeConditionsProvider: provider,
    );

    final CaptureEnvelope envelope = sdk.captureNow(reason: "snap-runtime");

    expect(provider.resolveCallCount, 1);
    final RuntimeConditionsSnapshot snapshot =
        await envelope.runtimeConditions.resolve();
    expect(snapshot.deviceModel, "Pixel 9 Pro");
    expect(snapshot.osVersion, "Android 16");
    expect(snapshot.networkType, "wifi");
    expect(provider.resolveCallCount, 1);
  });

  test("captureNow snaps state values immediately at capture time", () async {
    String screen = "checkout";
    int readCount = 0;
    final RevclustSdk sdk = RevclustSdk(
      config: SdkConfig(),
      monotonicClockMs: () => 0,
      stateSnapshotProvider: AllowlistedStateSnapshotProvider(
        appStateFields: <AppStateField>[
          AppStateField(
            key: "screen",
            readValue: () {
              readCount += 1;
              return screen;
            },
          ),
        ],
      ),
    );

    final CaptureEnvelope envelope = sdk.captureNow(reason: "snap-state");

    expect(readCount, 1);

    screen = "confirmation";
    final StateSnapshot snapshot = await envelope.stateSnapshot.resolve();
    expect(snapshot.appState["screen"], "checkout");
    expect(readCount, 1);
  });

  test("runtime validation rejects empty reason and blank signature", () {
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());

    expect(() => sdk.captureNow(reason: ""), throwsA(isA<ArgumentError>()));
    expect(() => sdk.captureNow(reason: "   "), throwsA(isA<ArgumentError>()));
    expect(
      () => sdk.captureNow(reason: "x", signature: "   "),
      throwsA(isA<ArgumentError>()),
    );
  });

  test("capture models validate required non-empty and non-negative fields",
      () {
    final CaptureTrigger validTrigger = CaptureTrigger(
      type: "manual",
      reason: "manual check",
    );

    expect(
      () => CaptureTrigger(type: "", reason: "x"),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => CaptureTrigger(type: "manual", reason: ""),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => CaptureTrigger(type: "manual", reason: "x", signature: "  "),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => CaptureEnvelope(
        captureId: " ",
        trigger: validTrigger,
        triggerUtcMs: 1,
        triggerMonoMs: 1,
        timeline: const <TimelineEvent>[],
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => CaptureEnvelope(
        captureId: "abc",
        trigger: validTrigger,
        triggerUtcMs: -1,
        triggerMonoMs: 1,
        timeline: const <TimelineEvent>[],
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => CaptureEnvelope(
        captureId: "abc",
        trigger: validTrigger,
        triggerUtcMs: 1,
        triggerMonoMs: -1,
        timeline: const <TimelineEvent>[],
      ),
      throwsA(isA<ArgumentError>()),
    );
  });
}

String _eventLabel(TimelineEvent event) {
  if (event.eventType == "ui.intent") {
    return "ui:${event.attributes["name"]}";
  }
  return event.eventType;
}

int Function() _sequenceClock(List<int> values) {
  int index = 0;
  return () {
    final int value = values[index];
    if (index < values.length - 1) {
      index += 1;
    }
    return value;
  };
}

class _SequencedRuntimeConditionsProvider implements RuntimeConditionsProvider {
  _SequencedRuntimeConditionsProvider(List<RuntimeConditionsSnapshot> snapshots)
      : _snapshots = List<RuntimeConditionsSnapshot>.from(snapshots);

  final List<RuntimeConditionsSnapshot> _snapshots;
  int resolveCallCount = 0;

  @override
  Future<RuntimeConditionsSnapshot> resolve() async {
    resolveCallCount += 1;
    if (_snapshots.isEmpty) {
      throw StateError("No runtime snapshots remaining.");
    }
    return _snapshots.removeAt(0);
  }
}
