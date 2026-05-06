import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter_sdk/src/capture/capture_envelope.dart";
import "package:revclust_flutter_sdk/src/capture/capture_trigger.dart";
import "package:revclust_flutter_sdk/src/checkpoint/checkpoint_coordinator.dart";
import "package:revclust_flutter_sdk/src/events/timeline_event.dart";
import "package:revclust_flutter_sdk/src/observability/sdk_logger.dart";
import "package:revclust_flutter_sdk/src/pack/pack_build_request.dart";
import "package:revclust_flutter_sdk/src/pack/pack_build_result.dart";
import "package:revclust_flutter_sdk/src/pack/pack_builder.dart";
import "package:revclust_flutter_sdk/src/update_context/session_state_store.dart";

void main() {
  group("CheckpointCoordinator", () {
    test("writes one checkpoint after 20 events", () async {
      final _Harness harness = _Harness();

      for (int i = 0; i < 19; i += 1) {
        await harness.coordinator.onEventRecorded();
      }

      expect(harness.repository.savedResults, isEmpty);

      await harness.coordinator.onEventRecorded();

      expect(harness.repository.savedResults, hasLength(1));
      expect(harness.builder.requests, hasLength(1));
      expect(harness.sessionStateStore.lastCheckpointWrites, hasLength(1));
      final CaptureEnvelope envelope =
          harness.builder.requests.single.captureEnvelope;
      expect(envelope.trigger.type, checkpointTriggerType);
      expect(envelope.trigger.reason, checkpointReasonCadenceEventCount);
    });

    test("counter resets only after successful checkpoint write", () async {
      final _Harness harness = _Harness();

      for (int i = 0; i < 20; i += 1) {
        await harness.coordinator.onEventRecorded();
      }
      expect(harness.repository.savedResults, hasLength(1));
      expect(harness.coordinator.eventsSinceLastSuccessfulCheckpoint, 0);

      harness.clock.advance(1000);
      for (int i = 0; i < 19; i += 1) {
        await harness.coordinator.onEventRecorded();
      }

      expect(harness.repository.savedResults, hasLength(1));
      expect(harness.coordinator.eventsSinceLastSuccessfulCheckpoint, 19);

      await harness.coordinator.onEventRecorded();

      expect(harness.repository.savedResults, hasLength(2));
      expect(harness.coordinator.eventsSinceLastSuccessfulCheckpoint, 0);
    });

    test("throttled trigger drops write and preserves counter", () async {
      final _Harness harness = _Harness();

      for (int i = 0; i < 20; i += 1) {
        await harness.coordinator.onEventRecorded();
      }
      expect(harness.repository.savedResults, hasLength(1));

      for (int i = 0; i < 20; i += 1) {
        await harness.coordinator.onEventRecorded();
      }

      expect(harness.repository.savedResults, hasLength(1));
      expect(harness.coordinator.eventsSinceLastSuccessfulCheckpoint, 20);

      harness.clock.advance(1000);
      await harness.coordinator.onEventRecorded();

      expect(harness.repository.savedResults, hasLength(2));
      expect(harness.coordinator.eventsSinceLastSuccessfulCheckpoint, 0);
    });

    test("5-second ticker trigger no-ops when no new events", () async {
      final _Harness harness = _Harness();

      harness.coordinator.startTicker();
      harness.clock.advance(5000);
      await harness.ticker.tick();

      expect(harness.repository.savedResults, isEmpty);
    });

    test("background transition no-ops when no new events", () async {
      final _Harness harness = _Harness();

      await harness.coordinator.onBackgroundTransition();

      expect(harness.repository.savedResults, isEmpty);
    });

    test("timer trigger writes once when new work exists", () async {
      final _Harness harness = _Harness();

      harness.coordinator.startTicker();
      await harness.coordinator.onEventRecorded();
      harness.clock.advance(5000);
      await harness.ticker.tick();

      expect(harness.repository.savedResults, hasLength(1));
      expect(
        harness.builder.requests.single.captureEnvelope.trigger.reason,
        checkpointReasonCadenceTimer,
      );
    });

    test(
        "checkpoint write builds, persists, and writes UTC checkpoint timestamp",
        () async {
      final _Harness harness = _Harness(initialUtcMs: 123456);

      await harness.coordinator.onEventRecorded();
      await harness.coordinator.onBackgroundTransition();

      expect(harness.builder.requests, hasLength(1));
      final CaptureEnvelope envelope =
          harness.builder.requests.single.captureEnvelope;
      expect(envelope.trigger.type, checkpointTriggerType);
      expect(harness.repository.savedResults, hasLength(1));
      expect(harness.sessionStateStore.lastCheckpointWrites, <int>[123456]);
    });

    test("throttled writes are not queued for automatic retry", () async {
      final _Harness harness = _Harness();

      await harness.coordinator.onEventRecorded();
      await harness.coordinator.onTickerTick();
      expect(harness.repository.savedResults, hasLength(1));

      await harness.coordinator.onEventRecorded();
      harness.clock.advance(100);
      await harness.coordinator.onTickerTick();
      expect(harness.repository.savedResults, hasLength(1));
      expect(harness.coordinator.eventsSinceLastSuccessfulCheckpoint, 1);

      harness.clock.advance(5000);
      expect(
        harness.repository.savedResults,
        hasLength(1),
        reason: "no new trigger means no retry",
      );

      await harness.coordinator.onTickerTick();
      expect(harness.repository.savedResults, hasLength(2));
    });

    test("logs structured checkpoint failures", () async {
      final List<SdkLogEntry> logs = <SdkLogEntry>[];
      final _Harness harness = _Harness(
        logger: logs.add,
        repositoryShouldThrow: true,
      );

      await harness.coordinator.onEventRecorded();

      await expectLater(
        harness.coordinator.onBackgroundTransition(),
        throwsA(isA<StateError>()),
      );

      expect(logs, hasLength(1));
      expect(logs.single.code, SdkLogCodes.checkpointFailed);
      expect(logs.single.level, SdkLogLevel.error);
      expect(logs.single.metadata["capture_id"], "checkpoint-1");
      expect(logs.single.metadata["reason"], checkpointReasonCadenceBackground);
      expect(logs.single.metadata["stage"], "persist_pack");
      expect(logs.single.metadata["error_type"], "StateError");
    });
  });
}

class _Harness {
  _Harness({
    int initialUtcMs = 10000,
    SdkLogger? logger,
    bool repositoryShouldThrow = false,
  })  : clock = _FakeUtcClock(initialUtcMs),
        ticker = _FakeCheckpointTicker(),
        builder = _RecordingPackBuilder(),
        repository = _InMemoryPackRepository(
          shouldThrow: repositoryShouldThrow,
        ),
        sessionStateStore = _FakeSessionStateStore() {
    coordinator = CheckpointCoordinator(
      packBuilder: builder,
      persistPack: repository.savePending,
      sessionStateStore: sessionStateStore,
      captureCheckpointEnvelope: _captureCheckpointEnvelope,
      buildPackRequest: _buildPackRequest,
      ticker: ticker,
      utcNowMs: clock.call,
      logger: logger,
    );
  }

  late final CheckpointCoordinator coordinator;
  final _FakeUtcClock clock;
  final _FakeCheckpointTicker ticker;
  final _RecordingPackBuilder builder;
  final _InMemoryPackRepository repository;
  final _FakeSessionStateStore sessionStateStore;

  int _captureCounter = 0;

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

  @override
  void start(Future<void> Function() onTick) {
    _onTick = onTick;
  }

  @override
  void stop() {
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
  final List<PackBuildRequest> requests = <PackBuildRequest>[];

  @override
  PackBuildResult build(PackBuildRequest request) {
    requests.add(request);
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

class _InMemoryPackRepository {
  _InMemoryPackRepository({this.shouldThrow = false});

  final List<PackBuildResult> savedResults = <PackBuildResult>[];
  final bool shouldThrow;

  Future<void> savePending(PackBuildResult result) async {
    if (shouldThrow) {
      throw StateError("simulated persistence failure");
    }
    savedResults.add(result);
  }
}

class _FakeSessionStateStore implements SessionStateStore {
  final List<int> lastCheckpointWrites = <int>[];
  String? _lastSeenVersion;
  bool? _cleanShutdown;

  @override
  Future<bool?> readCleanShutdown() async {
    return _cleanShutdown;
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
    _cleanShutdown = isCleanShutdown;
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
