/// Typed pack-build failure categories.
enum PackBuildFailureCode {
  terminalOversize,
  loopGuardExceeded,
}

/// Typed failure for pack build flow.
class PackBuildFailure implements Exception {
  PackBuildFailure._({
    required this.code,
    required this.message,
    required this.maxPackBytesGzip,
    required this.attemptedGzipBytes,
    required this.remainingTimelineEvents,
    required this.droppedBytes,
  });

  factory PackBuildFailure.terminalOversize({
    required int maxPackBytesGzip,
    required int attemptedGzipBytes,
    required int remainingTimelineEvents,
    required int droppedBytes,
  }) {
    return PackBuildFailure._(
      code: PackBuildFailureCode.terminalOversize,
      message:
          "Pack is still oversized after removing all timeline events. No artifact emitted.",
      maxPackBytesGzip: maxPackBytesGzip,
      attemptedGzipBytes: attemptedGzipBytes,
      remainingTimelineEvents: remainingTimelineEvents,
      droppedBytes: droppedBytes,
    );
  }

  factory PackBuildFailure.loopGuardExceeded({
    required int maxPackBytesGzip,
    required int attemptedGzipBytes,
    required int remainingTimelineEvents,
    required int droppedBytes,
  }) {
    return PackBuildFailure._(
      code: PackBuildFailureCode.loopGuardExceeded,
      message: "Pack truncation loop guard exceeded.",
      maxPackBytesGzip: maxPackBytesGzip,
      attemptedGzipBytes: attemptedGzipBytes,
      remainingTimelineEvents: remainingTimelineEvents,
      droppedBytes: droppedBytes,
    );
  }

  final PackBuildFailureCode code;
  final String message;
  final int maxPackBytesGzip;
  final int attemptedGzipBytes;
  final int remainingTimelineEvents;
  final int droppedBytes;

  @override
  String toString() {
    return "PackBuildFailure("
        "code: $code, "
        "message: $message, "
        "maxPackBytesGzip: $maxPackBytesGzip, "
        "attemptedGzipBytes: $attemptedGzipBytes, "
        "remainingTimelineEvents: $remainingTimelineEvents, "
        "droppedBytes: $droppedBytes"
        ")";
  }
}
