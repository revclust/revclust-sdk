import "dart:convert";

import "_validation.dart";

final RegExp _codePattern = RegExp(r"^[a-z0-9][a-z0-9_.-]{0,79}$");
final RegExp _factKeyPattern = RegExp(r"^[a-z0-9][a-z0-9_.-]{0,63}$");
final RegExp _subjectValuePattern =
    RegExp(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$");

const int _maxFactDepth = 4;
const int _maxFactMapEntries = 16;
const int _maxFactListItems = 16;
const int _maxFactStringLength = 256;
const int _maxFactJsonBytes = 4096;

const Set<String> _placeholderSubjectValues = <String>{
  "n/a",
  "na",
  "none",
  "null",
  "not_applicable",
  "not-applicable",
  "notapplicable",
  "tbd",
  "todo",
  "undefined",
  "unknown",
};

/// Factual app-owned invariant failure captured by Revclust.
final class RevclustInvariantFailure {
  /// Creates a product-shaped invariant failure.
  RevclustInvariantFailure({
    required String failureKind,
    required this.subject,
    required Map<String, Object?> expected,
    required Map<String, Object?> observed,
  })  : failureKind = _normalizeCode(failureKind, "failureKind"),
        expected = _normalizeNonEmptyObject(expected, "expected"),
        observed = _normalizeNonEmptyObject(observed, "observed");

  /// Stable failure class for title, grouping, and search.
  final String failureKind;

  /// Primary reproduction anchor for the failure.
  final RevclustSubject subject;

  /// Factual invariant the app expected.
  final Map<String, Object?> expected;

  /// Factual state, action, or result the app actually observed.
  final Map<String, Object?> observed;
}

/// Primary reproduction anchor attached to an invariant failure.
final class RevclustSubject {
  /// Creates a primary reproduction anchor.
  RevclustSubject({
    required String kind,
    required String value,
  })  : kind = _normalizeCode(kind, "kind"),
        value = _normalizeSubjectValue(value);

  /// Short code for the kind of anchor, such as `order_ref` or `flow`.
  final String kind;

  /// Privacy-safe anchor value.
  final String value;
}

String _normalizeCode(String value, String name) {
  final String normalized = normalizeRequiredString(value, name);
  if (!_codePattern.hasMatch(normalized)) {
    throw ArgumentError.value(
      value,
      name,
      "must match ${_codePattern.pattern}",
    );
  }
  return normalized;
}

Map<String, Object?> _normalizeNonEmptyObject(
  Map<String, Object?> value,
  String name,
) {
  final Map<String, Object?> normalized = _normalizeFactMap(
    value,
    name,
    depth: 0,
  );
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, "must not be empty");
  }
  final int byteLength = utf8.encode(jsonEncode(normalized)).length;
  if (byteLength > _maxFactJsonBytes) {
    throw ArgumentError.value(
      value,
      name,
      "must encode to at most $_maxFactJsonBytes JSON bytes",
    );
  }
  return Map<String, Object?>.unmodifiable(normalized);
}

String _normalizeSubjectValue(String value) {
  final String normalized = normalizeRequiredString(value, "value");
  final String lower = normalized.toLowerCase();
  if (_placeholderSubjectValues.contains(lower)) {
    throw ArgumentError.value(value, "value", "must not be a placeholder");
  }
  if (!_subjectValuePattern.hasMatch(normalized)) {
    throw ArgumentError.value(
      value,
      "value",
      "must match ${_subjectValuePattern.pattern}",
    );
  }
  return normalized;
}

Map<String, Object?> _normalizeFactMap(
  Map<Object?, Object?> value,
  String name, {
  required int depth,
}) {
  if (depth >= _maxFactDepth) {
    throw ArgumentError.value(value, name, "is nested too deeply");
  }
  if (value.length > _maxFactMapEntries) {
    throw ArgumentError.value(
      value,
      name,
      "must contain at most $_maxFactMapEntries entries",
    );
  }

  final Map<String, Object?> normalized = <String, Object?>{};
  for (final MapEntry<Object?, Object?> entry in value.entries) {
    final Object? key = entry.key;
    if (key is! String) {
      throw ArgumentError.value(key, "$name key", "must be a String");
    }
    final String normalizedKey = key.trim();
    if (!_factKeyPattern.hasMatch(normalizedKey)) {
      throw ArgumentError.value(
        key,
        "$name key",
        "must match ${_factKeyPattern.pattern}",
      );
    }
    if (normalized.containsKey(normalizedKey)) {
      throw ArgumentError.value(
        key,
        "$name key",
        "duplicates normalized key `$normalizedKey`",
      );
    }
    normalized[normalizedKey] = _normalizeFactValue(
      entry.value,
      "$name.$normalizedKey",
      depth: depth + 1,
    );
  }
  return normalized;
}

Object? _normalizeFactValue(
  Object? value,
  String name, {
  required int depth,
}) {
  if (value == null || value is bool) {
    return value;
  }
  if (value is num) {
    if (!value.isFinite) {
      throw ArgumentError.value(value, name, "must be finite");
    }
    return value;
  }
  if (value is String) {
    final String normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, name, "must not be empty");
    }
    if (normalized.length > _maxFactStringLength) {
      throw ArgumentError.value(
        value,
        name,
        "must be at most $_maxFactStringLength characters",
      );
    }
    return normalized;
  }
  if (value is Iterable) {
    if (depth >= _maxFactDepth) {
      throw ArgumentError.value(value, name, "is nested too deeply");
    }
    final List<Object?> normalized = <Object?>[];
    for (final Object? item in value) {
      if (normalized.length >= _maxFactListItems) {
        throw ArgumentError.value(
          value,
          name,
          "must contain at most $_maxFactListItems items",
        );
      }
      normalized.add(
        _normalizeFactValue(item, "$name[]", depth: depth + 1),
      );
    }
    return List<Object?>.unmodifiable(normalized);
  }
  if (value is Map<Object?, Object?>) {
    return Map<String, Object?>.unmodifiable(
      _normalizeFactMap(value, name, depth: depth),
    );
  }
  throw ArgumentError.value(value, name, "must be JSON-safe");
}
