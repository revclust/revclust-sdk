import "dart:convert";

/// Minimal event model for timeline capture.
class TimelineEvent {
  /// Creates a timeline event with a canonical event type and monotonic time.
  TimelineEvent({
    required String eventType,
    required int tMonoMs,
    this.attributes = const <String, Object?>{},
  })  : eventType = eventType.isEmpty
            ? throw ArgumentError.value(
                eventType,
                "eventType",
                "must not be empty",
              )
            : eventType,
        tMonoMs = tMonoMs < 0
            ? throw ArgumentError.value(tMonoMs, "tMonoMs", "must be >= 0")
            : tMonoMs;

  /// Event category identifier for `event_type` payload field.
  final String eventType;

  /// Monotonic timestamp in milliseconds.
  final int tMonoMs;

  /// Optional payload fields for future event variants.
  final Map<String, Object?> attributes;

  /// Approximate event byte accounting used for deterministic buffer eviction.
  int get estimatedByteSize {
    int size = utf8.encode(eventType).length + 8;
    final List<MapEntry<String, Object?>> entries = attributes.entries.toList()
      ..sort(
        (MapEntry<String, Object?> a, MapEntry<String, Object?> b) =>
            a.key.compareTo(b.key),
      );

    for (final MapEntry<String, Object?> entry in entries) {
      size += utf8.encode(entry.key).length;
      size += _estimateValueByteSize(entry.value);
    }
    return size;
  }
}

int _estimateValueByteSize(Object? value) {
  if (value == null || value is bool) {
    return 1;
  }
  if (value is num) {
    return 8;
  }
  if (value is String) {
    return utf8.encode(value).length;
  }
  if (value is Map<Object?, Object?>) {
    int size = 2;
    final List<MapEntry<Object?, Object?>> entries = value.entries.toList()
      ..sort(
        (MapEntry<Object?, Object?> a, MapEntry<Object?, Object?> b) =>
            a.key.toString().compareTo(b.key.toString()),
      );
    for (final MapEntry<Object?, Object?> entry in entries) {
      size += utf8.encode(entry.key.toString()).length;
      size += _estimateValueByteSize(entry.value);
    }
    return size;
  }
  if (value is Iterable<Object?>) {
    int size = 2;
    for (final Object? item in value) {
      size += _estimateValueByteSize(item);
    }
    return size;
  }
  return utf8.encode(value.toString()).length;
}
