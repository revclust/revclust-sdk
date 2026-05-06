import "_validation.dart";
import "revclust_identity.dart";

/// Narrow Tier 1 semantic trigger for a public Revclust capture.
final class RevclustTrigger {
  /// Creates a product-shaped trigger for one concrete incident.
  RevclustTrigger({
    required String reason,
    required this.identity,
    this.expected,
    this.observed,
    String? signature,
    String? flow,
    String? screen,
    String? stepLabel,
    String? reproHint,
    Map<String, String> relevantIds = const <String, String>{},
  })  : reason = normalizeRequiredString(reason, "reason"),
        signature = normalizeOptionalString(signature, "signature"),
        flow = normalizeOptionalString(flow, "flow"),
        screen = normalizeOptionalString(screen, "screen"),
        stepLabel = normalizeOptionalString(stepLabel, "stepLabel"),
        reproHint = normalizeOptionalString(reproHint, "reproHint"),
        relevantIds = Map<String, String>.unmodifiable(
            _normalizeRelevantIds(relevantIds));

  /// Human-readable incident reason.
  final String reason;

  /// Small expected oracle value captured with the trigger.
  final Object? expected;

  /// Small observed oracle value captured with the trigger.
  final Object? observed;

  /// Stable join handle for the incident.
  final RevclustIdentity identity;

  /// Optional canonical incident signature for grouping or alerting.
  final String? signature;

  /// Optional host-app flow hint for operator orientation.
  final String? flow;

  /// Optional screen hint for operator orientation.
  final String? screen;

  /// Optional step label for operator orientation.
  final String? stepLabel;

  /// Optional short reproduction hint for the incident.
  final String? reproHint;

  /// Optional small map of privacy-safe IDs relevant to the incident.
  final Map<String, String> relevantIds;

  static Map<String, String> _normalizeRelevantIds(Map<String, String> value) {
    final Map<String, String> normalized = <String, String>{};
    for (final MapEntry<String, String> entry in value.entries) {
      final String key = normalizeRequiredString(entry.key, "relevantIds key");
      normalized[key] = normalizeRequiredString(
        entry.value,
        'relevantIds["$key"]',
      );
    }
    return normalized;
  }
}
