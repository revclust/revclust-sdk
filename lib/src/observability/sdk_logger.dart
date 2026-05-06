import "dart:convert";
import "dart:developer" as developer;

/// Minimal structured logger callback used by the SDK.
typedef SdkLogger = void Function(SdkLogEntry entry);

/// Stable log levels emitted by the SDK.
enum SdkLogLevel {
  debug,
  info,
  warning,
  error,
}

/// Stable log codes emitted by the SDK.
class SdkLogCodes {
  SdkLogCodes._();

  static const String checkpointFailed = "sdk.checkpoint_failed";
  static const String localPersistenceFailed = "sdk.local_persistence_failed";
  static const String packBuildFailed = "sdk.pack_build_failed";
  static const String packTruncated = "sdk.pack_truncated";
  static const String runtimeConditionsFallback =
      "sdk.runtime_conditions_fallback";
  static const String runtimeConditionsMissing =
      "sdk.runtime_conditions_missing";
  static const String stateSnapshotFallback = "sdk.state_snapshot_fallback";
  static const String stateSnapshotOmitted = "sdk.state_snapshot_omitted";
}

/// Structured SDK log entry passed to host-provided loggers.
class SdkLogEntry {
  SdkLogEntry({
    required this.level,
    required this.code,
    required this.message,
    Map<String, Object?> metadata = const <String, Object?>{},
    this.stackTrace,
  }) : metadata = Map<String, Object?>.unmodifiable(metadata);

  final SdkLogLevel level;
  final String code;
  final String message;
  final Map<String, Object?> metadata;
  final StackTrace? stackTrace;
}

/// Built-in default logger used when apps do not provide a callback.
void defaultSdkLogger(SdkLogEntry entry) {
  final String metadataSuffix =
      entry.metadata.isEmpty ? "" : " ${jsonEncode(entry.metadata)}";
  developer.log(
    "${entry.message}$metadataSuffix",
    name: "revclust_flutter_sdk.${entry.code}",
    level: _developerLevel(entry.level),
    stackTrace: entry.stackTrace,
  );
}

int _developerLevel(SdkLogLevel level) {
  switch (level) {
    case SdkLogLevel.debug:
      return 500;
    case SdkLogLevel.info:
      return 800;
    case SdkLogLevel.warning:
      return 900;
    case SdkLogLevel.error:
      return 1000;
  }
}
