import "dart:async" show Timer, unawaited;

import "../capture/capture_envelope.dart";
import "../observability/sdk_logger.dart";
import "../pack/pack_build_request.dart";
import "../pack/pack_build_result.dart";
import "../pack/pack_builder.dart";
import "../update_context/session_state_store.dart";

const String checkpointTriggerType = "checkpoint";
const String checkpointReasonCadenceEventCount = "cadence.event_count";
const String checkpointReasonCadenceTimer = "cadence.timer";
const String checkpointReasonCadenceBackground = "cadence.background";

/// Abstraction for deterministic checkpoint cadence ticks.
abstract class CheckpointTicker {
  void start(Future<void> Function() onTick);

  void stop();
}

/// Default production ticker that emits periodic checkpoint ticks.
class PeriodicCheckpointTicker implements CheckpointTicker {
  PeriodicCheckpointTicker({Duration? interval})
      : _interval = interval ?? const Duration(seconds: 5);

  final Duration _interval;
  Timer? _timer;

  @override
  void start(Future<void> Function() onTick) {
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) {
      unawaited(onTick());
    });
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Coordinates cadence-based checkpoint writes.
class CheckpointCoordinator {
  CheckpointCoordinator({
    required PackBuilder packBuilder,
    required Future<void> Function(PackBuildResult result) persistPack,
    required SessionStateStore sessionStateStore,
    required CaptureEnvelope Function(String reason) captureCheckpointEnvelope,
    required Future<PackBuildRequest> Function(CaptureEnvelope envelope)
        buildPackRequest,
    CheckpointTicker? ticker,
    int Function()? utcNowMs,
    int eventCadenceCount = 20,
    int writeThrottleMs = 1000,
    SdkLogger? logger,
  })  : _packBuilder = packBuilder,
        _persistPack = persistPack,
        _sessionStateStore = sessionStateStore,
        _captureCheckpointEnvelope = captureCheckpointEnvelope,
        _buildPackRequest = buildPackRequest,
        _ticker = ticker ?? PeriodicCheckpointTicker(),
        _utcNowMs =
            utcNowMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch),
        _eventCadenceCount = _requirePositive(
            eventCadenceCount, "eventCadenceCount",
            allowZero: false),
        _writeThrottleMs = _requirePositive(
          writeThrottleMs,
          "writeThrottleMs",
          allowZero: true,
        ),
        _logger = logger;

  final PackBuilder _packBuilder;
  final Future<void> Function(PackBuildResult result) _persistPack;
  final SessionStateStore _sessionStateStore;
  final CaptureEnvelope Function(String reason) _captureCheckpointEnvelope;
  final Future<PackBuildRequest> Function(CaptureEnvelope envelope)
      _buildPackRequest;
  final CheckpointTicker _ticker;
  final int Function() _utcNowMs;
  final int _eventCadenceCount;
  final int _writeThrottleMs;
  final SdkLogger? _logger;

  int _eventsSinceLastSuccessfulCheckpoint = 0;
  int? _lastSuccessfulCheckpointUtcMs;
  bool _tickerStarted = false;
  Future<void> _serializedWork = Future<void>.value();

  int get eventsSinceLastSuccessfulCheckpoint =>
      _eventsSinceLastSuccessfulCheckpoint;

  Future<void> onEventRecorded() {
    return _enqueue(() async {
      _eventsSinceLastSuccessfulCheckpoint += 1;
      if (_eventsSinceLastSuccessfulCheckpoint < _eventCadenceCount) {
        return;
      }
      await _tryCheckpoint(reason: checkpointReasonCadenceEventCount);
    });
  }

  Future<void> onBackgroundTransition({CaptureEnvelope? envelope}) {
    return _enqueue(() async {
      await _tryCheckpoint(
        reason: checkpointReasonCadenceBackground,
        envelope: envelope,
      );
    });
  }

  Future<void> onTickerTick() {
    return _enqueue(() async {
      await _tryCheckpoint(reason: checkpointReasonCadenceTimer);
    });
  }

  void startTicker() {
    if (_tickerStarted) {
      return;
    }
    _tickerStarted = true;
    _ticker.start(onTickerTick);
  }

  void stopTicker() {
    if (!_tickerStarted) {
      return;
    }
    _tickerStarted = false;
    _ticker.stop();
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final Future<void> task = _serializedWork.then((_) => action());
    _serializedWork = task.catchError((Object _, StackTrace __) {});
    return task;
  }

  Future<void> _tryCheckpoint({
    required String reason,
    CaptureEnvelope? envelope,
  }) async {
    String stage = "preconditions";
    CaptureEnvelope? checkpointEnvelope = envelope;
    try {
      // Cadence triggers only checkpoint when new events exist since last success.
      if (_eventsSinceLastSuccessfulCheckpoint <= 0) {
        return;
      }

      final int nowUtcMs = _utcNowMs();
      if (nowUtcMs < 0) {
        throw StateError("utcNowMs must be >= 0.");
      }

      final int? lastSuccessUtcMs = _lastSuccessfulCheckpointUtcMs;
      if (lastSuccessUtcMs != null &&
          nowUtcMs - lastSuccessUtcMs < _writeThrottleMs) {
        return;
      }

      stage = "capture_envelope";
      checkpointEnvelope ??= _captureCheckpointEnvelope(reason);
      stage = "build_pack_request";
      final PackBuildRequest request =
          await _buildPackRequest(checkpointEnvelope);
      stage = "build_pack";
      final PackBuildResult result = _packBuilder.build(request);
      stage = "persist_pack";
      await _persistPack(result);
      stage = "write_checkpoint_timestamp";
      await _sessionStateStore.writeLastCheckpointTimestampMs(nowUtcMs);

      _lastSuccessfulCheckpointUtcMs = nowUtcMs;
      _eventsSinceLastSuccessfulCheckpoint = 0;
    } catch (error, stackTrace) {
      _logger?.call(
        SdkLogEntry(
          level: SdkLogLevel.error,
          code: SdkLogCodes.checkpointFailed,
          message: "Checkpoint write failed.",
          metadata: <String, Object?>{
            if (checkpointEnvelope != null)
              "capture_id": checkpointEnvelope.captureId,
            "error_type": error.runtimeType.toString(),
            "reason": reason,
            "stage": stage,
          },
          stackTrace: stackTrace,
        ),
      );
      rethrow;
    }
  }

  static int _requirePositive(
    int value,
    String name, {
    required bool allowZero,
  }) {
    if (allowZero ? value < 0 : value <= 0) {
      throw ArgumentError.value(
        value,
        name,
        allowZero ? "must be >= 0" : "must be > 0",
      );
    }
    return value;
  }
}
