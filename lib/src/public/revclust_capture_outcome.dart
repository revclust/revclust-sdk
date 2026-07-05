import "_validation.dart";
import "revclust_status.dart";

/// Immediate result returned by `captureInvariantFailure(...)`.
///
/// This surface is intentionally separate from later upload lifecycle events.
sealed class RevclustCaptureOutcome {
  const RevclustCaptureOutcome();
}

sealed class _RevclustCorrelatedCaptureOutcome extends RevclustCaptureOutcome {
  _RevclustCorrelatedCaptureOutcome({
    required String captureId,
  }) : captureId = normalizeRequiredString(captureId, "captureId");

  /// Stable capture identifier used to correlate later upload events.
  final String captureId;
}

/// Capture/build work was accepted and queued for later upload handling.
final class RevclustCaptureQueued extends _RevclustCorrelatedCaptureOutcome {
  RevclustCaptureQueued({
    required super.captureId,
  });
}

/// Capture was blocked before a real capture existed.
final class RevclustCaptureBlocked extends RevclustCaptureOutcome {
  RevclustCaptureBlocked({
    required this.status,
    String? message,
  })  : message = normalizeOptionalString(message, "message"),
        super();

  /// SDK status that explains the visible block condition.
  final RevclustStatus status;

  /// Optional human-readable explanation of the block condition.
  final String? message;
}

/// Capture reached build but failed before it could be queued for upload.
final class RevclustCaptureBuildFailed
    extends _RevclustCorrelatedCaptureOutcome {
  RevclustCaptureBuildFailed({
    required super.captureId,
    String? message,
  }) : message = normalizeOptionalString(message, "message");

  /// Optional human-readable explanation of the build failure.
  final String? message;
}

/// Capture built successfully but could not be persisted to the local queue.
final class RevclustCapturePersistenceFailed
    extends _RevclustCorrelatedCaptureOutcome {
  RevclustCapturePersistenceFailed({
    required super.captureId,
    String? message,
  }) : message = normalizeOptionalString(message, "message");

  /// Optional human-readable explanation of the persistence failure.
  final String? message;
}
