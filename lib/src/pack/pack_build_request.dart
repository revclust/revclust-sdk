import "../capture/capture_envelope.dart";
import "../update_context/update_context_snapshot.dart";

/// Input model for building a pack payload and gzip artifact.
class PackBuildRequest {
  PackBuildRequest({
    required this.captureEnvelope,
    required String sessionId,
    UpdateContextSnapshot? updateContextSnapshot,
    this.appVersion,
    this.build,
    this.deviceModel,
    this.osVersion,
    this.networkType,
    this.appReleaseStage,
    this.rttBucket,
    this.quality,
    this.gitSha,
    this.appState,
    this.dataState,
    int maxPackBytesGzip = 512 * 1024,
  })  : sessionId = _normalizeRequiredString(sessionId, "sessionId"),
        updateContextSnapshot =
            updateContextSnapshot ?? UpdateContextSnapshot.unknown,
        maxPackBytesGzip = _requirePositive(
          maxPackBytesGzip,
          "maxPackBytesGzip",
        );

  final CaptureEnvelope captureEnvelope;
  final String sessionId;
  final UpdateContextSnapshot updateContextSnapshot;

  /// Condition inputs (required schema fields use placeholders when absent).
  final String? appVersion;
  final String? build;
  final String? deviceModel;
  final String? osVersion;
  final String? networkType;
  final String? appReleaseStage;

  /// Optional condition inputs.
  final String? rttBucket;
  final String? quality;
  final String? gitSha;

  /// State snapshot inputs; defaults are empty maps if absent.
  final Map<String, Object?>? appState;
  final Map<String, Object?>? dataState;

  /// Strict cap evaluated against gzip-compressed payload bytes.
  final int maxPackBytesGzip;

  static String _normalizeRequiredString(String value, String name) {
    final String normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, name, "must not be empty");
    }
    return normalized;
  }

  static int _requirePositive(int value, String name) {
    if (value <= 0) {
      throw ArgumentError.value(value, name, "must be > 0");
    }
    return value;
  }
}
