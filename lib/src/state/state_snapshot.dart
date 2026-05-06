import "dart:collection";
import "dart:convert";

import "package:cryptography/cryptography.dart";

import "../observability/sdk_logger.dart";

/// Synchronous state reader invoked at the capture moment.
typedef StateValueReader = Object? Function();

/// Snapshot of allowlisted app/data state captured for an incident pack.
class StateSnapshot {
  const StateSnapshot({
    this.appState = const <String, Object?>{},
    this.dataState = const <String, Object?>{},
  });

  static const StateSnapshot empty = StateSnapshot();

  final Map<String, Object?> appState;
  final Map<String, Object?> dataState;
}

/// Capture-time handle for state snapshots that may resolve asynchronously.
class CapturedStateSnapshot {
  CapturedStateSnapshot._(this._snapshotFuture);

  factory CapturedStateSnapshot.snapshot(StateSnapshot snapshot) {
    return CapturedStateSnapshot.future(Future<StateSnapshot>.value(snapshot));
  }

  factory CapturedStateSnapshot.future(Future<StateSnapshot> snapshotFuture) {
    final Future<StateSnapshot> normalizedSnapshotFuture =
        Future<StateSnapshot>.sync(() async {
      try {
        return await snapshotFuture;
      } on Exception {
        return StateSnapshot.empty;
      }
    });
    return CapturedStateSnapshot._(normalizedSnapshotFuture);
  }

  factory CapturedStateSnapshot.capture(
    Future<StateSnapshot> Function() captureSnapshot,
  ) {
    return CapturedStateSnapshot.future(
      Future<StateSnapshot>.sync(captureSnapshot),
    );
  }

  static final CapturedStateSnapshot empty =
      CapturedStateSnapshot.snapshot(StateSnapshot.empty);

  final Future<StateSnapshot> _snapshotFuture;

  Future<StateSnapshot> resolve() {
    return _snapshotFuture;
  }
}

/// Allowlisted app-state field captured synchronously as bool/int/enum/string.
class AppStateField {
  AppStateField({
    required String key,
    required this.readValue,
  }) : key = _normalizeStateKey(key);

  final String key;
  final StateValueReader readValue;
}

/// Allowlisted data-state field captured synchronously as typed value or hash input.
class DataStateField {
  DataStateField.value({
    required String key,
    required this.readValue,
  })  : key = _normalizeStateKey(key),
        _kind = _DataStateFieldKind.value;

  DataStateField.hashedDomainId({
    required String key,
    required this.readValue,
  })  : key = _normalizeStateKey(key),
        _kind = _DataStateFieldKind.hashedDomainId;

  final String key;
  final StateValueReader readValue;
  final _DataStateFieldKind _kind;

  bool get isHashedDomainId => _kind == _DataStateFieldKind.hashedDomainId;
}

/// Static allowlist used to resolve FR3 state snapshot fields at capture time.
class AllowlistedStateSnapshotProvider {
  AllowlistedStateSnapshotProvider({
    List<AppStateField> appStateFields = const <AppStateField>[],
    List<DataStateField> dataStateFields = const <DataStateField>[],
    HashAlgorithm? hashAlgorithm,
    SdkLogger? logger,
  })  : _appStateFields = _sortedUniqueAppFields(appStateFields),
        _dataStateFields = _sortedUniqueDataFields(dataStateFields),
        _hashAlgorithm = hashAlgorithm ?? Sha256(),
        _logger = logger;

  final List<AppStateField> _appStateFields;
  final List<DataStateField> _dataStateFields;
  final HashAlgorithm _hashAlgorithm;
  final SdkLogger? _logger;

  bool get requiresHashSalt =>
      _dataStateFields.any((DataStateField field) => field.isHashedDomainId);

  Future<StateSnapshot> capture({
    required int maxStateKeys,
    required int maxStateBytes,
    required int maxStringLen,
    String? hashSalt,
  }) async {
    final _StateSnapshotDiagnostics diagnostics = _StateSnapshotDiagnostics();
    // Snap raw field values before any async post-processing can observe
    // later mutations in the underlying source.
    final List<_CapturedAppStateEntry> capturedAppEntries =
        _captureAppStateEntries(diagnostics);
    final List<_CapturedDataStateEntry> capturedDataEntries =
        _captureDataStateEntries(diagnostics);
    final List<_ResolvedStateEntry> candidates = <_ResolvedStateEntry>[];

    for (final _CapturedAppStateEntry entry in capturedAppEntries) {
      final Object? value = _resolveAppStateValue(
        entry.rawValue,
        maxStringLen: maxStringLen,
      );
      if (value != null) {
        candidates.add(
          _ResolvedStateEntry(
            kind: _StateEntryKind.app,
            key: entry.key,
            value: value,
          ),
        );
      } else {
        diagnostics.record(
          "unsupported_or_missing",
          "app_state.${entry.key}",
        );
      }
    }

    for (final _CapturedDataStateEntry entry in capturedDataEntries) {
      final Object? value = await _resolveDataStateValue(
        entry.rawValue,
        isHashedDomainId: entry.isHashedDomainId,
        maxStringLen: maxStringLen,
        hashSalt: hashSalt,
      );
      if (value != null) {
        candidates.add(
          _ResolvedStateEntry(
            kind: _StateEntryKind.data,
            key: entry.key,
            value: value,
          ),
        );
      } else {
        diagnostics.record(
          entry.isHashedDomainId
              ? "hash_or_invalid_domain_id"
              : "unsupported_or_missing",
          "data_state.${entry.key}",
        );
      }
    }

    final SplayTreeMap<String, Object?> appState =
        SplayTreeMap<String, Object?>();
    final SplayTreeMap<String, Object?> dataState =
        SplayTreeMap<String, Object?>();
    int includedKeys = 0;
    int maxStateKeysExceededAt = -1;

    for (int index = 0; index < candidates.length; index += 1) {
      final _ResolvedStateEntry entry = candidates[index];
      if (includedKeys >= maxStateKeys) {
        maxStateKeysExceededAt = index;
        break;
      }

      final SplayTreeMap<String, Object?> nextAppState =
          SplayTreeMap<String, Object?>.from(appState);
      final SplayTreeMap<String, Object?> nextDataState =
          SplayTreeMap<String, Object?>.from(dataState);
      switch (entry.kind) {
        case _StateEntryKind.app:
          nextAppState[entry.key] = entry.value;
        case _StateEntryKind.data:
          nextDataState[entry.key] = entry.value;
      }

      if (_estimateSnapshotBytes(nextAppState, nextDataState) > maxStateBytes) {
        diagnostics.record(
          "max_state_bytes_exceeded",
          _stateFieldPath(entry),
        );
        continue;
      }

      switch (entry.kind) {
        case _StateEntryKind.app:
          appState[entry.key] = entry.value;
        case _StateEntryKind.data:
          dataState[entry.key] = entry.value;
      }
      includedKeys += 1;
    }

    if (maxStateKeysExceededAt >= 0) {
      for (final _ResolvedStateEntry entry in candidates.skip(
        maxStateKeysExceededAt,
      )) {
        if (!diagnostics.containsField(_stateFieldPath(entry))) {
          diagnostics.record(
            "max_state_keys_exceeded",
            _stateFieldPath(entry),
          );
        }
      }
    }

    if (diagnostics.hasEntries) {
      _logger?.call(
        SdkLogEntry(
          level: SdkLogLevel.warning,
          code: SdkLogCodes.stateSnapshotOmitted,
          message: "State snapshot omitted one or more allowlisted fields.",
          metadata: <String, Object?>{
            "max_state_bytes": maxStateBytes,
            "max_state_keys": maxStateKeys,
            "omitted_fields_by_reason": diagnostics.toMetadata(),
          },
        ),
      );
    }

    return StateSnapshot(
      appState: Map<String, Object?>.unmodifiable(appState),
      dataState: Map<String, Object?>.unmodifiable(dataState),
    );
  }

  List<_CapturedAppStateEntry> _captureAppStateEntries(
    _StateSnapshotDiagnostics diagnostics,
  ) {
    final List<_CapturedAppStateEntry> capturedEntries =
        <_CapturedAppStateEntry>[];
    for (final AppStateField field in _appStateFields) {
      try {
        capturedEntries.add(
          _CapturedAppStateEntry(
            key: field.key,
            rawValue: field.readValue(),
          ),
        );
      } on Exception {
        diagnostics.record("read_failure", "app_state.${field.key}");
        continue;
      }
    }
    return capturedEntries;
  }

  List<_CapturedDataStateEntry> _captureDataStateEntries(
    _StateSnapshotDiagnostics diagnostics,
  ) {
    final List<_CapturedDataStateEntry> capturedEntries =
        <_CapturedDataStateEntry>[];
    for (final DataStateField field in _dataStateFields) {
      try {
        capturedEntries.add(
          _CapturedDataStateEntry(
            key: field.key,
            isHashedDomainId: field.isHashedDomainId,
            rawValue: field.readValue(),
          ),
        );
      } on Exception {
        diagnostics.record("read_failure", "data_state.${field.key}");
        continue;
      }
    }
    return capturedEntries;
  }

  Object? _resolveAppStateValue(
    Object? rawValue, {
    required int maxStringLen,
  }) {
    return _normalizeTypedValue(rawValue, maxStringLen: maxStringLen);
  }

  Future<Object?> _resolveDataStateValue(
    Object? rawValue, {
    required bool isHashedDomainId,
    required int maxStringLen,
    required String? hashSalt,
  }) async {
    if (!isHashedDomainId) {
      return _normalizeTypedValue(rawValue, maxStringLen: maxStringLen);
    }

    try {
      final String normalizedHashSalt = _normalizeRequiredHashSalt(hashSalt);
      final String? normalizedDomainId = _normalizeDomainId(rawValue);
      if (normalizedDomainId == null) {
        return null;
      }
      return await _hashDomainId(normalizedHashSalt, normalizedDomainId);
    } on Exception {
      return null;
    }
  }

  Future<String> _hashDomainId(String hashSalt, String domainId) async {
    final Hash hash = await _hashAlgorithm.hash(
      utf8.encode("$hashSalt:$domainId"),
    );
    return "sha256:${_encodeHex(hash.bytes)}";
  }

  static List<AppStateField> _sortedUniqueAppFields(
    List<AppStateField> fields,
  ) {
    final List<AppStateField> sorted = List<AppStateField>.from(fields)
      ..sort((AppStateField a, AppStateField b) => a.key.compareTo(b.key));
    _throwIfDuplicateKeys(sorted.map((AppStateField field) => field.key));
    return List<AppStateField>.unmodifiable(sorted);
  }

  static List<DataStateField> _sortedUniqueDataFields(
    List<DataStateField> fields,
  ) {
    final List<DataStateField> sorted = List<DataStateField>.from(fields)
      ..sort((DataStateField a, DataStateField b) => a.key.compareTo(b.key));
    _throwIfDuplicateKeys(sorted.map((DataStateField field) => field.key));
    return List<DataStateField>.unmodifiable(sorted);
  }

  static void _throwIfDuplicateKeys(Iterable<String> keys) {
    final Set<String> seen = <String>{};
    for (final String key in keys) {
      if (!seen.add(key)) {
        throw ArgumentError.value(key, "key", "must be unique");
      }
    }
  }

  static Object? _normalizeTypedValue(
    Object? value, {
    required int maxStringLen,
  }) {
    if (value == null || value is bool || value is int) {
      return value;
    }
    if (value is Enum) {
      return _truncateString(value.name, maxStringLen);
    }
    if (value is String) {
      return _truncateString(value, maxStringLen);
    }
    return null;
  }

  static String? _normalizeDomainId(Object? value) {
    if (value is int) {
      return value.toString();
    }
    if (value is Enum) {
      return value.name;
    }
    if (value is String) {
      final String normalized = value.trim();
      if (normalized.isEmpty) {
        return null;
      }
      return normalized;
    }
    return null;
  }

  static String _normalizeRequiredHashSalt(String? value) {
    if (value == null) {
      throw StateError(
        "SdkConfig.stateHashSalt is required when using hashed domain IDs.",
      );
    }
    final String normalized = value.trim();
    if (normalized.isEmpty) {
      throw StateError(
        "SdkConfig.stateHashSalt must not be empty when using hashed domain IDs.",
      );
    }
    return normalized;
  }

  static String _truncateString(String value, int maxStringLen) {
    if (value.length <= maxStringLen) {
      return value;
    }
    return value.substring(0, maxStringLen);
  }

  static int _estimateSnapshotBytes(
    Map<String, Object?> appState,
    Map<String, Object?> dataState,
  ) {
    return utf8
        .encode(
          jsonEncode(<String, Object?>{
            "app_state": appState,
            "data_state": dataState,
          }),
        )
        .length;
  }

  static String _encodeHex(List<int> bytes) {
    final StringBuffer buffer = StringBuffer();
    for (final int byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, "0"));
    }
    return buffer.toString();
  }

  static String _stateFieldPath(_ResolvedStateEntry entry) {
    switch (entry.kind) {
      case _StateEntryKind.app:
        return "app_state.${entry.key}";
      case _StateEntryKind.data:
        return "data_state.${entry.key}";
    }
  }
}

class _StateSnapshotDiagnostics {
  final SplayTreeMap<String, SplayTreeSet<String>> _fieldsByReason =
      SplayTreeMap<String, SplayTreeSet<String>>();

  bool get hasEntries => _fieldsByReason.isNotEmpty;

  bool containsField(String fieldPath) {
    return _fieldsByReason.values.any(
      (SplayTreeSet<String> fields) => fields.contains(fieldPath),
    );
  }

  void record(String reason, String fieldPath) {
    _fieldsByReason.putIfAbsent(reason, () => SplayTreeSet<String>()).add(
          fieldPath,
        );
  }

  Map<String, Object?> toMetadata() {
    return Map<String, Object?>.unmodifiable(
      _fieldsByReason.map(
        (String reason, SplayTreeSet<String> fields) => MapEntry(
          reason,
          List<String>.unmodifiable(fields.toList(growable: false)),
        ),
      ),
    );
  }
}

enum _DataStateFieldKind {
  value,
  hashedDomainId,
}

enum _StateEntryKind {
  app,
  data,
}

class _ResolvedStateEntry {
  const _ResolvedStateEntry({
    required this.kind,
    required this.key,
    required this.value,
  });

  final _StateEntryKind kind;
  final String key;
  final Object value;
}

class _CapturedAppStateEntry {
  const _CapturedAppStateEntry({
    required this.key,
    required this.rawValue,
  });

  final String key;
  final Object? rawValue;
}

class _CapturedDataStateEntry {
  const _CapturedDataStateEntry({
    required this.key,
    required this.isHashedDomainId,
    required this.rawValue,
  });

  final String key;
  final bool isHashedDomainId;
  final Object? rawValue;
}

String _normalizeStateKey(String value) {
  final String normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, "key", "must not be empty");
  }
  return normalized;
}
