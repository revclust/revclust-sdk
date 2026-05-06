final RegExp _integerSegmentPattern = RegExp(r"^\d+$");
final RegExp _uuidLikeSegmentPattern = RegExp(
  r"^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$",
  caseSensitive: false,
);
final RegExp _longHexSegmentPattern = RegExp(
  r"^[0-9a-f]{16,}$",
  caseSensitive: false,
);
final RegExp _sensitiveUrlDelimiterPattern = RegExp(r"[/?#@=&]");

/// Returns a deterministic path with identifier-like segments replaced by `{id}`.
///
/// This strips query parameters and fragments while preserving path slash shape.
String sanitizeNetworkPath(String pathOrUrl) {
  final String input = pathOrUrl.trim();
  if (input.isEmpty) {
    throw ArgumentError.value(pathOrUrl, "pathOrUrl", "must not be empty");
  }

  final String strippedPath = _extractPathWithoutQueryOrFragment(input);
  if (strippedPath.isEmpty) {
    return "/";
  }

  final List<String> segments = strippedPath.split("/");
  final String sanitizedPath =
      segments.map((String segment) => _sanitizeSegment(segment)).join("/");

  return sanitizedPath.isEmpty ? "/" : sanitizedPath;
}

String _extractPathWithoutQueryOrFragment(String value) {
  final Uri? parsed = Uri.tryParse(value);
  if (parsed != null && (parsed.hasScheme || parsed.host.isNotEmpty)) {
    return parsed.path.isEmpty ? "/" : parsed.path;
  }

  int end = value.length;
  final int queryIndex = value.indexOf("?");
  if (queryIndex >= 0 && queryIndex < end) {
    end = queryIndex;
  }
  final int fragmentIndex = value.indexOf("#");
  if (fragmentIndex >= 0 && fragmentIndex < end) {
    end = fragmentIndex;
  }
  return value.substring(0, end);
}

String _sanitizeSegment(String segment) {
  if (segment.isEmpty) {
    return segment;
  }

  String candidate = segment;
  try {
    candidate = Uri.decodeComponent(segment);
  } on FormatException {
    // Use raw segment if percent-decoding fails.
  }

  if (_integerSegmentPattern.hasMatch(candidate) ||
      _uuidLikeSegmentPattern.hasMatch(candidate) ||
      _longHexSegmentPattern.hasMatch(candidate) ||
      _sensitiveUrlDelimiterPattern.hasMatch(candidate)) {
    return "{id}";
  }
  return segment;
}
