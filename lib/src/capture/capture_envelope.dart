import "../events/timeline_event.dart";
import "../runtime/runtime_conditions.dart";
import "../state/state_snapshot.dart";
import "capture_trigger.dart";

/// In-memory capture artifact returned by trigger APIs.
class CaptureEnvelope {
  CaptureEnvelope({
    required String captureId,
    required this.trigger,
    required int triggerUtcMs,
    required int triggerMonoMs,
    required List<TimelineEvent> timeline,
    CapturedRuntimeConditions? runtimeConditions,
    CapturedStateSnapshot? stateSnapshot,
  })  : captureId = _normalizeRequiredString(captureId, "captureId"),
        triggerUtcMs = _requireNonNegative(triggerUtcMs, "triggerUtcMs"),
        triggerMonoMs = _requireNonNegative(triggerMonoMs, "triggerMonoMs"),
        timeline = List<TimelineEvent>.unmodifiable(timeline),
        runtimeConditions =
            runtimeConditions ?? CapturedRuntimeConditions.unknown,
        stateSnapshot = stateSnapshot ?? CapturedStateSnapshot.empty;

  /// UUID v4 identifier for this capture.
  final String captureId;

  /// Trigger metadata used to create this capture.
  final CaptureTrigger trigger;

  /// Wall-clock UTC timestamp (epoch ms) captured at trigger time.
  final int triggerUtcMs;

  /// SDK monotonic timestamp (ms) captured at trigger time.
  final int triggerMonoMs;

  /// Timeline events sliced for this capture.
  final List<TimelineEvent> timeline;

  /// FR2 runtime conditions snapped at capture time for later pack building.
  final CapturedRuntimeConditions runtimeConditions;

  /// FR3 allowlisted state snapped at capture time for later pack building.
  final CapturedStateSnapshot stateSnapshot;

  static String _normalizeRequiredString(String value, String name) {
    final String normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, name, "must not be empty");
    }
    return normalized;
  }

  static int _requireNonNegative(int value, String name) {
    if (value < 0) {
      throw ArgumentError.value(value, name, "must be >= 0");
    }
    return value;
  }
}
