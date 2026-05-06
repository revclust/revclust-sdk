import "_validation.dart";

/// Current best-known queue or upload state for the public facade.
final class RevclustUploadSnapshot {
  /// Creates the current upload snapshot view.
  RevclustUploadSnapshot({
    int pendingCount = 0,
    int uploadingCount = 0,
    this.lastErrorCode,
  })  : pendingCount = normalizeNonNegativeInt(pendingCount, "pendingCount"),
        uploadingCount =
            normalizeNonNegativeInt(uploadingCount, "uploadingCount");

  /// Count of captures waiting for upload handling.
  final int pendingCount;

  /// Count of captures currently uploading.
  final int uploadingCount;

  /// Optional coarse last-known error code for queue or upload handling.
  final RevclustUploadErrorCode? lastErrorCode;
}

/// Lean queue or upload error taxonomy for MVP and pilot facade status.
enum RevclustUploadErrorCode {
  transportUnavailable,
  auth,
  misconfiguration,
  invalidRequest,
  unsupportedSchema,
  blobTooLarge,
  internalError,
}
