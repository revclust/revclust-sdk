import "_validation.dart";

/// Later upload lifecycle event correlated by `captureId`.
sealed class RevclustUploadEvent {
  RevclustUploadEvent({
    required String captureId,
  }) : captureId = normalizeRequiredString(captureId, "captureId");

  /// Capture identifier shared with the immediate capture outcome.
  final String captureId;
}

/// Upload work started for a previously queued capture.
final class RevclustUploadStarted extends RevclustUploadEvent {
  RevclustUploadStarted({
    required super.captureId,
  });
}

/// Upload completed and the hosted backend accepted the capture.
final class RevclustUploadAccepted extends RevclustUploadEvent {
  RevclustUploadAccepted({
    required super.captureId,
    required this.result,
  });

  /// Typed hosted accept details assembled from hosted acceptance and local SDK observation.
  final RevclustAcceptedResult result;
}

/// Upload completed but the hosted backend rejected the capture.
final class RevclustUploadRejected extends RevclustUploadEvent {
  RevclustUploadRejected({
    required super.captureId,
    required this.code,
    String? message,
  }) : message = normalizeOptionalString(message, "message");

  /// Lean hosted rejection taxonomy for integrations.
  final RevclustRejectionCode code;

  /// Optional human-readable rejection message.
  final String? message;
}

/// Upload failed before an accepted or rejected ingest response was received.
final class RevclustTransportFailure extends RevclustUploadEvent {
  RevclustTransportFailure({
    required super.captureId,
    int? statusCode,
    String? message,
    this.retryable = false,
  })  : statusCode = normalizeOptionalPositiveInt(statusCode, "statusCode"),
        message = normalizeOptionalString(message, "message");

  /// Optional HTTP status code observed on the failed transport attempt.
  final int? statusCode;

  /// Optional human-readable transport failure summary.
  final String? message;

  /// Whether the failure appears retryable from the SDK point of view.
  final bool retryable;
}

/// Small typed accept details assembled from the hosted accept response and local SDK timing.
final class RevclustAcceptedResult {
  /// Creates typed hosted accept details.
  RevclustAcceptedResult({
    required String packId,
    required String schemaVersion,
    required int blobBytesGzip,
    required this.acceptedAt,
    this.viewerUrl,
  })  : packId = normalizeRequiredString(packId, "packId"),
        schemaVersion = normalizeRequiredString(
          schemaVersion,
          "schemaVersion",
        ),
        blobBytesGzip = normalizeNonNegativeInt(
          blobBytesGzip,
          "blobBytesGzip",
        );

  /// Hosted pack identifier.
  final String packId;

  /// Canonical schema version for the accepted pack artifact, such as `1.0.0`.
  final String schemaVersion;

  /// Gzipped pack size acknowledged by the hosted backend.
  final int blobBytesGzip;

  /// SDK-observed time when hosted acceptance was confirmed locally.
  final DateTime acceptedAt;

  /// Optional engineer-facing viewer URL for the accepted incident.
  final Uri? viewerUrl;
}

/// Lean rejection taxonomy for hosted upload flows.
enum RevclustRejectionCode {
  auth,
  misconfiguration,
  invalidRequest,
  unsupportedSchema,
  blobTooLarge,
  internalError,
}
