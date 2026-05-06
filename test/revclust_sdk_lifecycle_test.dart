import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter_sdk/revclust_flutter_sdk.dart";
import "package:revclust_flutter_sdk/src/update_context/session_state_store.dart";

void main() {
  group("RevclustSdk lifecycle", () {
    test("dispose stops cadence ticker and is idempotent", () async {
      final _SdkLifecycleHarness harness = _SdkLifecycleHarness();

      await harness.coordinator.onEventRecorded();
      harness.clock.advance(5000);
      await harness.ticker.tick();
      expect(harness.persistedResults, hasLength(1));

      await harness.sdk.dispose();
      expect(harness.ticker.stopCount, 1);

      harness.clock.advance(5000);
      await expectLater(harness.ticker.tick(), throwsStateError);
      expect(
        harness.persistedResults,
        hasLength(1),
        reason: "dispose must prevent additional ticker-triggered writes",
      );

      await harness.sdk.dispose();
      expect(harness.ticker.stopCount, 1);
    });

    test("dispose and markCleanShutdown are safe together", () async {
      final _SdkLifecycleHarness harness = _SdkLifecycleHarness();

      await harness.sdk.dispose();
      await harness.sdk.markCleanShutdown();
      await harness.sdk.dispose();
      await harness.sdk.markCleanShutdown();

      expect(harness.sessionStateStore.cleanShutdownWrites, <bool>[true, true]);
      expect(harness.sessionStateStore.lastCheckpointWrites, hasLength(2));
    });
  });
}

class _SdkLifecycleHarness {
  _SdkLifecycleHarness()
      : clock = _FakeUtcClock(10000),
        ticker = _FakeCheckpointTicker(),
        sessionStateStore = _RecordingSessionStateStore(),
        builder = _RecordingPackBuilder() {
    coordinator = CheckpointCoordinator(
      packBuilder: builder,
      persistPack: _persist,
      sessionStateStore: sessionStateStore,
      captureCheckpointEnvelope: _captureCheckpointEnvelope,
      buildPackRequest: _buildPackRequest,
      ticker: ticker,
      utcNowMs: clock.call,
    );

    sdk = RevclustSdk(
      config: SdkConfig(),
      sessionStateStore: sessionStateStore,
      checkpointCoordinator: coordinator,
    );
  }

  late final RevclustSdk sdk;
  late final CheckpointCoordinator coordinator;
  final _FakeUtcClock clock;
  final _FakeCheckpointTicker ticker;
  final _RecordingSessionStateStore sessionStateStore;
  final _RecordingPackBuilder builder;
  final List<PackBuildResult> persistedResults = <PackBuildResult>[];

  int _captureCounter = 0;

  Future<void> _persist(PackBuildResult result) async {
    persistedResults.add(result);
  }

  CaptureEnvelope _captureCheckpointEnvelope(String reason) {
    _captureCounter += 1;
    return CaptureEnvelope(
      captureId: "checkpoint-$_captureCounter",
      trigger: CaptureTrigger(type: checkpointTriggerType, reason: reason),
      triggerUtcMs: clock.call(),
      triggerMonoMs: clock.call(),
      timeline: const <TimelineEvent>[],
    );
  }

  Future<PackBuildRequest> _buildPackRequest(CaptureEnvelope envelope) async {
    return PackBuildRequest(
      captureEnvelope: envelope,
      sessionId: "session-id",
    );
  }
}

class _FakeUtcClock {
  _FakeUtcClock(this._nowMs);

  int _nowMs;

  int call() => _nowMs;

  void advance(int deltaMs) {
    _nowMs += deltaMs;
  }
}

class _FakeCheckpointTicker implements CheckpointTicker {
  Future<void> Function()? _onTick;
  int stopCount = 0;

  @override
  void start(Future<void> Function() onTick) {
    _onTick = onTick;
  }

  @override
  void stop() {
    stopCount += 1;
    _onTick = null;
  }

  Future<void> tick() async {
    final Future<void> Function()? callback = _onTick;
    if (callback == null) {
      throw StateError("Ticker was not started.");
    }
    await callback();
  }
}

class _RecordingPackBuilder extends PackBuilder {
  @override
  PackBuildResult build(PackBuildRequest request) {
    return PackBuildResult(
      payload: <String, Object?>{
        "capture_id": request.captureEnvelope.captureId
      },
      gzipBytes: Uint8List.fromList(<int>[1, 2, 3]),
      truncated: false,
      droppedCountsByType: const <String, int>{},
      droppedBytes: 0,
    );
  }
}

class _RecordingSessionStateStore implements SessionStateStore {
  final List<int> lastCheckpointWrites = <int>[];
  final List<bool> cleanShutdownWrites = <bool>[];

  String? _lastSeenVersion;

  @override
  Future<bool?> readCleanShutdown() async {
    if (cleanShutdownWrites.isEmpty) {
      return null;
    }
    return cleanShutdownWrites.last;
  }

  @override
  Future<int?> readLastCheckpointTimestampMs() async {
    if (lastCheckpointWrites.isEmpty) {
      return null;
    }
    return lastCheckpointWrites.last;
  }

  @override
  Future<String?> readLastSeenAppVersion() async {
    return _lastSeenVersion;
  }

  @override
  Future<void> writeCleanShutdown(bool isCleanShutdown) async {
    cleanShutdownWrites.add(isCleanShutdown);
  }

  @override
  Future<void> writeLastCheckpointTimestampMs(int timestampMs) async {
    lastCheckpointWrites.add(timestampMs);
  }

  @override
  Future<void> writeLastSeenAppVersion(String appVersion) async {
    _lastSeenVersion = appVersion;
  }
}
