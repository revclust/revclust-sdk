String normalizeRequiredString(String value, String name) {
  final String normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, "must not be empty");
  }
  return normalized;
}

String? normalizeOptionalString(String? value, String name) {
  if (value == null) {
    return null;
  }
  final String normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, "must not be empty");
  }
  return normalized;
}

int normalizeNonNegativeInt(int value, String name) {
  if (value < 0) {
    throw ArgumentError.value(value, name, "must be >= 0");
  }
  return value;
}

int normalizePositiveInt(int value, String name) {
  if (value <= 0) {
    throw ArgumentError.value(value, name, "must be > 0");
  }
  return value;
}

int? normalizeOptionalPositiveInt(int? value, String name) {
  if (value == null) {
    return null;
  }
  if (value <= 0) {
    throw ArgumentError.value(value, name, "must be > 0");
  }
  return value;
}
