import "package:shared_preferences/shared_preferences.dart";

const String revclustLastSeenAppVersionStorageKey =
    "revclust_last_seen_app_version";
const String revclustCleanShutdownStorageKey = "revclust_clean_shutdown";
const String revclustLastCheckpointTimestampMsStorageKey =
    "revclust_last_checkpoint_timestamp_ms";

/// Small persistence adapter for SDK session/lifecycle state bookkeeping.
abstract class SessionStateStore {
  Future<String?> readLastSeenAppVersion();

  Future<void> writeLastSeenAppVersion(String appVersion);

  Future<bool?> readCleanShutdown();

  Future<void> writeCleanShutdown(bool isCleanShutdown);

  Future<int?> readLastCheckpointTimestampMs();

  Future<void> writeLastCheckpointTimestampMs(int timestampMs);
}

class SharedPreferencesSessionStateStore implements SessionStateStore {
  SharedPreferencesSessionStateStore({
    Future<SharedPreferences> Function()? sharedPreferencesFactory,
  }) : _sharedPreferencesFactory =
            sharedPreferencesFactory ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _sharedPreferencesFactory;

  @override
  Future<String?> readLastSeenAppVersion() async {
    final SharedPreferences prefs = await _sharedPreferencesFactory();
    final String? storedVersion = prefs.getString(
      revclustLastSeenAppVersionStorageKey,
    );
    return _normalizeNullableString(storedVersion);
  }

  @override
  Future<void> writeLastSeenAppVersion(String appVersion) async {
    final String normalizedVersion = _normalizeRequiredString(
      appVersion,
      "appVersion",
    );
    final SharedPreferences prefs = await _sharedPreferencesFactory();
    await prefs.setString(
      revclustLastSeenAppVersionStorageKey,
      normalizedVersion,
    );
  }

  @override
  Future<bool?> readCleanShutdown() async {
    final SharedPreferences prefs = await _sharedPreferencesFactory();
    return prefs.getBool(revclustCleanShutdownStorageKey);
  }

  @override
  Future<void> writeCleanShutdown(bool isCleanShutdown) async {
    final SharedPreferences prefs = await _sharedPreferencesFactory();
    await prefs.setBool(revclustCleanShutdownStorageKey, isCleanShutdown);
  }

  @override
  Future<int?> readLastCheckpointTimestampMs() async {
    final SharedPreferences prefs = await _sharedPreferencesFactory();
    return prefs.getInt(revclustLastCheckpointTimestampMsStorageKey);
  }

  @override
  Future<void> writeLastCheckpointTimestampMs(int timestampMs) async {
    if (timestampMs < 0) {
      throw ArgumentError.value(timestampMs, "timestampMs", "must be >= 0");
    }
    final SharedPreferences prefs = await _sharedPreferencesFactory();
    await prefs.setInt(
      revclustLastCheckpointTimestampMsStorageKey,
      timestampMs,
    );
  }

  static String _normalizeRequiredString(String value, String name) {
    final String normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, name, "must not be empty");
    }
    return normalized;
  }

  static String? _normalizeNullableString(String? value) {
    if (value == null) {
      return null;
    }
    final String normalized = value.trim();
    if (normalized.isEmpty) {
      return null;
    }
    return normalized;
  }
}
