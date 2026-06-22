import "dart:collection";
import "dart:convert";

import "package:dio/dio.dart";
import "package:sqflite/sqflite.dart" as sqflite;

import "../capture/capture_envelope.dart";
import "../config/sdk_config.dart";
import "../core/revclust_sdk.dart";
import "../network/revclust_dio_interceptor.dart";
import "../pack/pack_build_failure.dart";
import "../pack/pack_build_result.dart";
import "../persistence/aes_gcm_encryption_service.dart";
import "../persistence/key_store.dart";
import "../persistence/local_pack_repository.dart";
import "../persistence/revclust_database_factory.dart";
import "../state/state_snapshot.dart";
import "revclust_capture_outcome.dart";
import "revclust_config.dart";
import "revclust_invariant_failure.dart";

/// Internal deterministic local storage namespace for the public facade.
final class RevclustFacadeLocalStorageScope {
  const RevclustFacadeLocalStorageScope({
    required this.databaseFileName,
    required this.storageKey,
  });

  final String databaseFileName;
  final String storageKey;
}

RevclustFacadeLocalStorageScope resolveRevclustFacadeLocalStorageScope(
  RevclustConfig config,
) {
  final String scopeId = _projectStorageScopeId(config.projectKey);
  return RevclustFacadeLocalStorageScope(
    databaseFileName: "revclust_public_facade_$scopeId.db",
    storageKey: "revclust_public_facade_encryption_key_$scopeId",
  );
}

/// Internal local-capture runtime factory for the public facade.
abstract interface class RevclustFacadeLocalCaptureFactory {
  Future<RevclustFacadeLocalCapture> create(RevclustConfig config);
}

typedef RevclustFacadeKeyStoreFactory = KeyStore Function(
  RevclustFacadeLocalStorageScope storageScope,
  String databasePath,
);

typedef RevclustFacadeDatabaseDirectoryResolver = Future<String> Function(
    sqflite.DatabaseFactory databaseFactory);

/// Internal local-capture runtime used behind the public facade.
abstract interface class RevclustFacadeLocalCapture {
  LocalPackRepository get repository;

  void setStateSnapshotProvider(StateSnapshot Function()? provider);

  void enableDioCapture(Dio dio);

  void recordUiIntent({
    required String name,
    Map<String, Object?> attributes = const <String, Object?>{},
  });

  void recordScreenTransition({
    required String fromScreen,
    required String toScreen,
    Map<String, Object?> attributes = const <String, Object?>{},
  });

  Future<RevclustCaptureOutcome> captureInvariantFailure(
    RevclustInvariantFailure failure,
  );

  Future<int> countPending();

  Future<void> dispose();
}

final class DefaultRevclustFacadeLocalCaptureFactory
    implements RevclustFacadeLocalCaptureFactory {
  const DefaultRevclustFacadeLocalCaptureFactory({
    RevclustFacadeKeyStoreFactory? keyStoreFactory,
    RevclustFacadeDatabaseDirectoryResolver? databaseDirectoryResolver,
  })  : _keyStoreFactory = keyStoreFactory,
        _databaseDirectoryResolver = databaseDirectoryResolver;

  final RevclustFacadeKeyStoreFactory? _keyStoreFactory;
  final RevclustFacadeDatabaseDirectoryResolver? _databaseDirectoryResolver;

  @override
  Future<RevclustFacadeLocalCapture> create(RevclustConfig config) async {
    final RevclustFacadeStateSnapshotAdapter stateSnapshotAdapter =
        RevclustFacadeStateSnapshotAdapter();
    final sqflite.DatabaseFactory databaseFactory =
        resolveRevclustDatabaseFactory();
    final String databaseDirectory = await _resolveDatabaseDirectory(
      databaseFactory,
    );
    final RevclustFacadeLocalStorageScope storageScope =
        resolveRevclustFacadeLocalStorageScope(config);
    final String databasePath = _joinPath(
      databaseDirectory,
      storageScope.databaseFileName,
    );
    final KeyStore keyStore =
        (_keyStoreFactory ?? resolveRevclustFacadeKeyStore)(
      storageScope,
      databasePath,
    );
    final LocalPackRepository repository = LocalPackRepository(
      encryptionService: AesGcmEncryptionService(
        keyStore: keyStore,
      ),
      databasePath: databasePath,
      databaseFactory: databaseFactory,
    );
    final RevclustSdk sdk = RevclustSdk(
      config: SdkConfig(
        appVersion: config.appVersion,
        build: config.build,
        gitSha: config.gitSha,
        appReleaseStage: config.releaseStage?.value,
      ),
      stateSnapshotProvider: stateSnapshotAdapter,
    );
    try {
      await sdk.initializeUpdateContext();
    } catch (_) {
      // Build metadata still reaches pack conditions; update-context
      // persistence must not block local capture startup.
    }
    return DefaultRevclustFacadeLocalCapture(
      sdk: sdk,
      repository: repository,
      stateSnapshotAdapter: stateSnapshotAdapter,
    );
  }

  static String _joinPath(String directory, String fileName) {
    if (directory.endsWith("/") || directory.endsWith("\\")) {
      return "$directory$fileName";
    }
    return "$directory/$fileName";
  }

  Future<String> _resolveDatabaseDirectory(
    sqflite.DatabaseFactory databaseFactory,
  ) async {
    final RevclustFacadeDatabaseDirectoryResolver? resolver =
        _databaseDirectoryResolver;
    if (resolver != null) {
      return resolver(databaseFactory);
    }
    return databaseFactory.getDatabasesPath();
  }
}

KeyStore resolveRevclustFacadeKeyStore(
  RevclustFacadeLocalStorageScope storageScope,
  String databasePath,
) {
  final FlutterSecureStorageKeyStore secureStorageKeyStore =
      FlutterSecureStorageKeyStore(
    storageKey: storageScope.storageKey,
  );
  if (!isRevclustSupportedDesktopRuntime) {
    return secureStorageKeyStore;
  }

  // The pilot desktop path must keep queueing even when the OS keyring is
  // unavailable; on-device encryption is not part of the pilot baseline.
  return DesktopPilotFallbackKeyStore(
    secureStorageKeyStore: secureStorageKeyStore,
    fallbackKeyStore: FileBackedKeyStore(filePath: "$databasePath.key"),
  );
}

final class DefaultRevclustFacadeLocalCapture
    implements RevclustFacadeLocalCapture {
  DefaultRevclustFacadeLocalCapture({
    required RevclustSdk sdk,
    required LocalPackRepository repository,
    required RevclustFacadeStateSnapshotAdapter stateSnapshotAdapter,
  })  : _sdk = sdk,
        _repository = repository,
        _stateSnapshotAdapter = stateSnapshotAdapter;

  final RevclustSdk _sdk;
  final LocalPackRepository _repository;
  final RevclustFacadeStateSnapshotAdapter _stateSnapshotAdapter;
  final Map<Dio, RevclustDioInterceptor> _interceptorsByDio =
      LinkedHashMap<Dio, RevclustDioInterceptor>.identity();

  @override
  LocalPackRepository get repository => _repository;

  @override
  void setStateSnapshotProvider(StateSnapshot Function()? provider) {
    _stateSnapshotAdapter.provider = provider;
  }

  @override
  void enableDioCapture(Dio dio) {
    if (_interceptorsByDio.containsKey(dio)) {
      return;
    }
    final RevclustDioInterceptor interceptor = RevclustDioInterceptor(
      sdk: _sdk,
    );
    dio.interceptors.add(interceptor);
    _interceptorsByDio[dio] = interceptor;
  }

  @override
  void recordUiIntent({
    required String name,
    Map<String, Object?> attributes = const <String, Object?>{},
  }) {
    final String? normalizedName = _normalizeBreadcrumbRequiredString(name);
    if (normalizedName == null) {
      return;
    }

    try {
      _sdk.recordUiIntent(
        tMonoMs: _sdk.monotonicClockMs(),
        name: normalizedName,
        attributes: _copyReviewedBreadcrumbAttributes(attributes),
      );
    } on Object {
      // Reviewed breadcrumbs are best-effort and must not throw into app UI.
    }
  }

  @override
  void recordScreenTransition({
    required String fromScreen,
    required String toScreen,
    Map<String, Object?> attributes = const <String, Object?>{},
  }) {
    final String? normalizedFromScreen =
        _normalizeBreadcrumbRequiredString(fromScreen);
    final String? normalizedToScreen =
        _normalizeBreadcrumbRequiredString(toScreen);
    if (normalizedFromScreen == null || normalizedToScreen == null) {
      return;
    }

    try {
      _sdk.recordScreenTransition(
        tMonoMs: _sdk.monotonicClockMs(),
        fromScreen: normalizedFromScreen,
        toScreen: normalizedToScreen,
        attributes: _copyReviewedBreadcrumbAttributes(attributes),
      );
    } on Object {
      // Reviewed breadcrumbs are best-effort and must not throw into app UI.
    }
  }

  @override
  Future<RevclustCaptureOutcome> captureInvariantFailure(
    RevclustInvariantFailure failure,
  ) async {
    final CaptureEnvelope captureEnvelope = _sdk.captureInvariantFailure(
      failureKind: failure.failureKind,
      subjectKind: failure.subject.kind,
      subjectValue: failure.subject.value,
      expected: copyCaptureValue(failure.expected),
      observed: copyCaptureValue(failure.observed),
    );

    final PackBuildResult packBuildResult;
    try {
      packBuildResult = await _sdk.buildPack(
        captureEnvelope: captureEnvelope,
      );
    } catch (error) {
      return RevclustCaptureBuildFailed(
        captureId: captureEnvelope.captureId,
        message: _describeBuildError(error),
      );
    }

    try {
      await _repository.savePendingWithMetadata(
        packBuildResult,
        metadata: LocalPendingCaptureMetadata(
          captureId: captureEnvelope.captureId,
          failureKind: failure.failureKind,
          subjectKind: failure.subject.kind,
          subjectValue: failure.subject.value,
        ),
      );
    } catch (_) {
      return RevclustCapturePersistenceFailed(
        captureId: captureEnvelope.captureId,
        message: _describePersistenceError(),
      );
    }
    return RevclustCaptureQueued(captureId: captureEnvelope.captureId);
  }

  @override
  Future<int> countPending() => _repository.countPending();

  @override
  Future<void> dispose() async {
    await _sdk.dispose();
    await _repository.close();
  }

  static String _describeBuildError(Object error) {
    if (error is PackBuildFailure) {
      return error.message;
    }
    return "Canonical pack build failed before the capture could be queued.";
  }

  static String _describePersistenceError() {
    return "Local pending capture persistence failed after pack build.";
  }
}

String _projectStorageScopeId(String projectKey) {
  final BigInt offsetBasis = BigInt.parse("cbf29ce484222325", radix: 16);
  final BigInt prime = BigInt.parse("100000001b3", radix: 16);
  final BigInt maxUint64 = BigInt.parse("ffffffffffffffff", radix: 16);

  BigInt hash = offsetBasis;
  for (final int codeUnit in projectKey.codeUnits) {
    hash ^= BigInt.from(codeUnit);
    hash = (hash * prime) & maxUint64;
  }
  return hash.toRadixString(16).padLeft(16, "0");
}

const int _maxReviewedBreadcrumbAttributes = 16;
const int _maxReviewedBreadcrumbAttributeBytes = 4096;
const int _maxReviewedBreadcrumbStringLen = 256;
const int _maxReviewedBreadcrumbDepth = 4;

final Object _unsupportedReviewedBreadcrumbValue = Object();

Map<String, Object?> _copyReviewedBreadcrumbAttributes(
  Map<String, Object?> source,
) {
  final Map<String, Object?> copied = <String, Object?>{};
  for (final MapEntry<String, Object?> entry in source.entries) {
    if (copied.length >= _maxReviewedBreadcrumbAttributes) {
      break;
    }

    final String key = entry.key.trim();
    if (key.isEmpty || copied.containsKey(key)) {
      continue;
    }

    final Object? value = _copyReviewedBreadcrumbValue(
      entry.value,
      depth: 0,
    );
    if (identical(value, _unsupportedReviewedBreadcrumbValue)) {
      continue;
    }

    final Map<String, Object?> candidate = <String, Object?>{
      ...copied,
      key: value,
    };
    if (_jsonByteLength(candidate) > _maxReviewedBreadcrumbAttributeBytes) {
      continue;
    }
    copied[key] = value;
  }
  return Map<String, Object?>.unmodifiable(copied);
}

Object? _copyReviewedBreadcrumbValue(Object? value, {required int depth}) {
  if (value == null) {
    return null;
  }
  if (value is String) {
    return _truncateString(value, _maxReviewedBreadcrumbStringLen);
  }
  if (value is num) {
    return value.isFinite ? value : _unsupportedReviewedBreadcrumbValue;
  }
  if (value is bool) {
    return value;
  }
  if (depth >= _maxReviewedBreadcrumbDepth) {
    return _unsupportedReviewedBreadcrumbValue;
  }
  if (value is Iterable) {
    final List<Object?> copied = <Object?>[];
    try {
      for (final Object? item in value) {
        final Object? copiedItem = _copyReviewedBreadcrumbValue(
          item,
          depth: depth + 1,
        );
        if (!identical(copiedItem, _unsupportedReviewedBreadcrumbValue)) {
          copied.add(copiedItem);
        }
      }
    } on Object {
      return _unsupportedReviewedBreadcrumbValue;
    }
    return List<Object?>.unmodifiable(copied);
  }
  if (value is Map) {
    final Map<String, Object?> copied = <String, Object?>{};
    try {
      for (final MapEntry<dynamic, dynamic> entry in value.entries) {
        final Object? rawKey = entry.key;
        if (rawKey is! String) {
          continue;
        }
        final String key = rawKey.trim();
        if (key.isEmpty || copied.containsKey(key)) {
          continue;
        }
        final Object? copiedValue = _copyReviewedBreadcrumbValue(
          entry.value,
          depth: depth + 1,
        );
        if (!identical(copiedValue, _unsupportedReviewedBreadcrumbValue)) {
          copied[key] = copiedValue;
        }
      }
    } on Object {
      return _unsupportedReviewedBreadcrumbValue;
    }
    return Map<String, Object?>.unmodifiable(copied);
  }
  return _unsupportedReviewedBreadcrumbValue;
}

String? _normalizeBreadcrumbRequiredString(String value) {
  final String normalized = value.trim();
  return normalized.isEmpty
      ? null
      : _truncateString(normalized, _maxReviewedBreadcrumbStringLen);
}

int _jsonByteLength(Object? value) => utf8.encode(jsonEncode(value)).length;

final class RevclustFacadeStateSnapshotAdapter
    extends AllowlistedStateSnapshotProvider {
  StateSnapshot Function()? provider;

  @override
  Future<StateSnapshot> capture({
    required int maxStateKeys,
    required int maxStateBytes,
    required int maxStringLen,
    String? hashSalt,
  }) async {
    final StateSnapshot Function()? currentProvider = provider;
    if (currentProvider == null) {
      return StateSnapshot.empty;
    }
    final StateSnapshot snapshot = currentProvider();
    return copyBoundedStateSnapshot(
      snapshot,
      maxStateKeys: maxStateKeys,
      maxStateBytes: maxStateBytes,
      maxStringLen: maxStringLen,
    );
  }
}

StateSnapshot copyBoundedStateSnapshot(
  StateSnapshot snapshot, {
  required int maxStateKeys,
  required int maxStateBytes,
  required int maxStringLen,
}) {
  final Map<String, Object?> appState = <String, Object?>{};
  final Map<String, Object?> dataState = <String, Object?>{};
  int includedKeys = 0;

  void considerEntry(
    Map<String, Object?> target,
    MapEntry<String, Object?> entry,
  ) {
    if (includedKeys >= maxStateKeys) {
      return;
    }
    final String key = entry.key.trim();
    if (key.isEmpty) {
      return;
    }
    final Object? value = copyBoundedStateValue(
      entry.value,
      maxStringLen: maxStringLen,
    );
    if (value == null) {
      return;
    }

    final bool hadExistingValue = target.containsKey(key);
    final Object? previousValue = target[key];
    target[key] = value;
    if (_stateSnapshotByteLength(appState, dataState) > maxStateBytes) {
      if (hadExistingValue) {
        target[key] = previousValue;
      } else {
        target.remove(key);
      }
      return;
    }
    if (!hadExistingValue) {
      includedKeys += 1;
    }
  }

  for (final MapEntry<String, Object?> entry in snapshot.appState.entries) {
    considerEntry(appState, entry);
  }
  for (final MapEntry<String, Object?> entry in snapshot.dataState.entries) {
    considerEntry(dataState, entry);
  }

  return StateSnapshot(
    appState: Map<String, Object?>.unmodifiable(appState),
    dataState: Map<String, Object?>.unmodifiable(dataState),
  );
}

Map<String, Object?> copyStateMap(Map<String, Object?> source) {
  final Map<String, Object?> copied = <String, Object?>{};
  for (final MapEntry<String, Object?> entry in source.entries) {
    copied[entry.key] = copyCaptureValue(entry.value);
  }
  return Map<String, Object?>.unmodifiable(copied);
}

Object? copyCaptureValue(Object? value) {
  if (value == null || value is num || value is bool || value is String) {
    if (value is num && !value.isFinite) {
      return null;
    }
    return value;
  }
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(value.map<Object?>(copyCaptureValue));
  }
  if (value is List<dynamic>) {
    return List<Object?>.unmodifiable(value.map<Object?>(copyCaptureValue));
  }
  if (value is Map<String, Object?>) {
    return copyStateMap(value);
  }
  if (value is Map<Object?, Object?>) {
    final Map<String, Object?> normalized = <String, Object?>{};
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      if (entry.key is String) {
        normalized[entry.key! as String] = copyCaptureValue(entry.value);
      }
    }
    return Map<String, Object?>.unmodifiable(normalized);
  }
  return null;
}

Object? copyBoundedStateValue(
  Object? value, {
  required int maxStringLen,
}) {
  if (value == null) {
    return null;
  }
  if (value is num) {
    return value.isFinite ? value : null;
  }
  if (value is bool) {
    return value;
  }
  if (value is String) {
    return _truncateString(value, maxStringLen);
  }
  if (value is Iterable<Object?>) {
    return List<Object?>.unmodifiable(
      value.map<Object?>(
        (Object? item) => copyBoundedStateValue(
          item,
          maxStringLen: maxStringLen,
        ),
      ),
    );
  }
  if (value is Iterable<dynamic>) {
    return List<Object?>.unmodifiable(
      value.map<Object?>(
        (dynamic item) => copyBoundedStateValue(
          item as Object?,
          maxStringLen: maxStringLen,
        ),
      ),
    );
  }
  if (value is Map<Object?, Object?>) {
    final Map<String, Object?> normalized = <String, Object?>{};
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      final Object? key = entry.key;
      if (key is! String || key.trim().isEmpty) {
        continue;
      }
      final Object? copied = copyBoundedStateValue(
        entry.value,
        maxStringLen: maxStringLen,
      );
      if (copied != null) {
        normalized[key.trim()] = copied;
      }
    }
    return Map<String, Object?>.unmodifiable(normalized);
  }
  return null;
}

int _stateSnapshotByteLength(
  Map<String, Object?> appState,
  Map<String, Object?> dataState,
) {
  return utf8
      .encode(jsonEncode(<String, Object?>{
        "app_state": appState,
        "data_state": dataState,
      }))
      .length;
}

String _truncateString(String value, int maxStringLen) {
  if (value.length <= maxStringLen) {
    return value;
  }
  return value.substring(0, maxStringLen);
}
