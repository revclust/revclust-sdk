import "_validation.dart";

/// Stable Tier 1 identity handle attached to a public capture trigger.
final class RevclustIdentity {
  /// Creates a stable incident identity handle.
  RevclustIdentity({
    required String kind,
    required String value,
  })  : kind = normalizeRequiredString(kind, "kind"),
        value = normalizeRequiredString(value, "value");

  /// Short category name for the stable incident handle.
  final String kind;

  /// Stable identifier value for the incident handle.
  final String value;
}
