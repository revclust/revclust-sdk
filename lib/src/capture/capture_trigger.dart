/// Trigger metadata captured at incident capture time.
class CaptureTrigger {
  CaptureTrigger({
    required String type,
    String? reason,
    this.expected,
    this.observed,
    String? signature,
    Map<String, Object?> attributes = const <String, Object?>{},
  })  : type = _normalizeRequiredString(type, "type"),
        reason = _normalizeOptionalString(reason, "reason"),
        signature = _normalizeOptionalString(signature, "signature"),
        attributes = Map<String, Object?>.unmodifiable(attributes);

  /// Trigger category (for example: `manual`, `programmatic`).
  final String type;

  /// Optional SDK-owned legacy trigger reason.
  final String? reason;

  /// Optional expected oracle value.
  final Object? expected;

  /// Optional observed oracle value.
  final Object? observed;

  /// Optional oracle signature when provided by the caller.
  final String? signature;

  /// Optional JSON-safe trigger attributes carried into the pack payload.
  final Map<String, Object?> attributes;

  static String _normalizeRequiredString(String value, String name) {
    final String normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, name, "must not be empty");
    }
    return normalized;
  }

  static String? _normalizeOptionalString(String? value, String name) {
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
