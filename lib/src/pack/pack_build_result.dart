import "dart:typed_data";

/// Success result for pack build output.
class PackBuildResult {
  PackBuildResult({
    required Map<String, Object?> payload,
    required Uint8List gzipBytes,
    required this.truncated,
    required Map<String, int> droppedCountsByType,
    required this.droppedBytes,
  })  : payload = Map<String, Object?>.unmodifiable(payload),
        gzipBytes = Uint8List.fromList(gzipBytes),
        droppedCountsByType = Map<String, int>.unmodifiable(
          droppedCountsByType,
        );

  final Map<String, Object?> payload;
  final Uint8List gzipBytes;

  /// Mirrors payload.truncation.truncated.
  final bool truncated;

  /// Mirrors payload.truncation.dropped_counts_by_type.
  final Map<String, int> droppedCountsByType;

  /// Mirrors payload.truncation.dropped_bytes.
  final int droppedBytes;
}
