import "../observability/sdk_logger.dart";

/// Typed SDK configuration placeholders for early package bootstrapping.
class SdkConfig {
  /// Creates a minimal SDK configuration.
  SdkConfig({
    this.enabled = true,
    SdkLogger? logger,
    double sessionSampleRate = 1.0,
    int bufferWindowSec = 30,
    int maxTimelineEvents = 200,
    int maxTimelineBytes = 256 * 1024,
    int maxStateKeys = 32,
    int maxStateBytes = 8 * 1024,
    int maxStringLen = 256,
    String? stateHashSalt,
    String? appVersion,
    String? build,
  })  : sessionSampleRate = (sessionSampleRate < 0 || sessionSampleRate > 1)
            ? throw ArgumentError.value(
                sessionSampleRate,
                "sessionSampleRate",
                "must be in [0, 1]",
              )
            : sessionSampleRate,
        bufferWindowSec = bufferWindowSec <= 0
            ? throw ArgumentError.value(
                bufferWindowSec,
                "bufferWindowSec",
                "must be > 0",
              )
            : bufferWindowSec,
        maxTimelineEvents = maxTimelineEvents <= 0
            ? throw ArgumentError.value(
                maxTimelineEvents,
                "maxTimelineEvents",
                "must be > 0",
              )
            : maxTimelineEvents,
        maxTimelineBytes = maxTimelineBytes <= 0
            ? throw ArgumentError.value(
                maxTimelineBytes,
                "maxTimelineBytes",
                "must be > 0",
              )
            : maxTimelineBytes,
        maxStateKeys = maxStateKeys <= 0
            ? throw ArgumentError.value(
                maxStateKeys,
                "maxStateKeys",
                "must be > 0",
              )
            : maxStateKeys,
        maxStateBytes = maxStateBytes <= 0
            ? throw ArgumentError.value(
                maxStateBytes,
                "maxStateBytes",
                "must be > 0",
              )
            : maxStateBytes,
        maxStringLen = maxStringLen <= 0
            ? throw ArgumentError.value(
                maxStringLen,
                "maxStringLen",
                "must be > 0",
              )
            : maxStringLen,
        stateHashSalt = _normalizeOptionalNonEmptyString(
          stateHashSalt,
          "stateHashSalt",
        ),
        appVersion = _normalizeOptionalNonEmptyString(
          appVersion,
          "appVersion",
        ),
        build = _normalizeOptionalNonEmptyString(
          build,
          "build",
        ),
        logger = logger ?? defaultSdkLogger;

  /// Toggles SDK activity at runtime.
  final bool enabled;

  /// Optional structured logger callback used for SDK diagnostics.
  final SdkLogger logger;

  /// Fraction of sessions to keep, in the range 0.0 to 1.0.
  final double sessionSampleRate;

  /// Window size for timeline capture and slicing.
  final int bufferWindowSec;

  /// Maximum timeline events retained in memory before oldest eviction.
  final int maxTimelineEvents;

  /// Maximum estimated bytes retained in memory before oldest eviction.
  final int maxTimelineBytes;

  /// Maximum combined state keys retained in an FR3 snapshot.
  final int maxStateKeys;

  /// Maximum JSON bytes retained for an FR3 state snapshot object.
  final int maxStateBytes;

  /// Maximum string length retained for FR3 string/enum values.
  final int maxStringLen;

  /// Per-project salt used when hashing FR3 data-state domain IDs.
  final String? stateHashSalt;

  /// Current app version used for update-context detection when provided.
  final String? appVersion;

  /// Current build identifier available for future pack conditions.
  final String? build;

  static String? _normalizeOptionalNonEmptyString(String? value, String name) {
    if (value == null) {
      return null;
    }
    final String normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, name, "must not be empty");
    }
    return normalized;
  }
}
