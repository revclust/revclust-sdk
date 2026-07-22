import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:revclust_flutter/revclust_flutter.dart" as facade;
import "package:revclust_flutter/src/internal/revclust_internal.dart"
    as low_level;
import "package:revclust_flutter/src/persistence/revclust_database_factory.dart";
import "package:revclust_flutter/src/public/revclust_local_capture.dart"
    as facade_internal;
import "package:revclust_flutter/src/update_context/session_state_store.dart";

import "in_memory_key_store.dart";

final class TestPublicFacadeLocalCaptureFactory
    implements facade_internal.RevclustFacadeLocalCaptureFactory {
  TestPublicFacadeLocalCaptureFactory({
    low_level.PackBuilder? packBuilder,
    this.seededPendingCaptures = const <SeededPendingCapture>[],
    low_level.RuntimeConditionsProvider Function()?
        runtimeConditionsProviderFactory,
    this.failingCreateAttempts = 0,
    this.failPersistenceAfterBuild = false,
    int Function()? utcNowMs,
  })  : _packBuilder = packBuilder ?? low_level.PackBuilder(),
        _utcNowMs =
            utcNowMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch),
        _runtimeConditionsProviderFactory =
            runtimeConditionsProviderFactory ?? _defaultRuntimeProviderFactory;

  final low_level.PackBuilder _packBuilder;
  final List<SeededPendingCapture> seededPendingCaptures;
  final low_level.RuntimeConditionsProvider Function()
      _runtimeConditionsProviderFactory;
  final int failingCreateAttempts;
  final bool failPersistenceAfterBuild;
  final int Function() _utcNowMs;
  final InMemoryKeyStore _keyStore = InMemoryKeyStore();

  Directory? _tempDirectory;
  String? _databasePath;
  bool _seeded = false;
  int createCallCount = 0;

  low_level.LocalPackRepository? repository;
  low_level.RevclustSdk? sdk;

  @override
  Future<facade_internal.RevclustFacadeLocalCapture> create(
    facade.RevclustConfig config,
  ) async {
    createCallCount++;
    if (createCallCount <= failingCreateAttempts) {
      throw StateError("simulated local capture initialization failure");
    }

    final String databasePath = await _ensureDatabasePath();
    final _TestLocalPackRepository localRepository = _TestLocalPackRepository(
      encryptionService: low_level.AesGcmEncryptionService(keyStore: _keyStore),
      databasePath: databasePath,
      databaseFactory: resolveRevclustDatabaseFactory(),
      failPersistenceAfterBuild: failPersistenceAfterBuild,
      utcNowMs: _utcNowMs,
    );
    repository = localRepository;
    if (!_seeded) {
      _seeded = true;
      for (final SeededPendingCapture seed in seededPendingCaptures) {
        await localRepository.savePendingWithMetadata(
          seed.result,
          metadata: seed.metadata,
        );
      }
    }
    localRepository.enableRuntimePersistenceBehavior();

    final facade_internal.RevclustFacadeStateSnapshotAdapter adapter =
        facade_internal.RevclustFacadeStateSnapshotAdapter();
    final low_level.RevclustSdk sdk = low_level.RevclustSdk(
      config: low_level.SdkConfig(
        appVersion: config.appVersion,
        build: config.build,
        gitSha: config.gitSha,
        appReleaseStage: config.releaseStage?.value,
      ),
      packBuilder: _packBuilder,
      sessionStateStore: _MemorySessionStateStore(),
      runtimeConditionsProvider: _runtimeConditionsProviderFactory(),
      stateSnapshotProvider: adapter,
    );
    await sdk.initializeUpdateContext();
    this.sdk = sdk;

    return facade_internal.DefaultRevclustFacadeLocalCapture(
      sdk: sdk,
      repository: localRepository,
      stateSnapshotAdapter: adapter,
    );
  }

  Future<void> dispose() async {
    await sdk?.dispose();
    await repository?.close();
    final Directory? tempDirectory = _tempDirectory;
    if (tempDirectory != null && await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  }

  Future<int> countPending() async {
    final low_level.LocalPackRepository localRepository = _requireRepository();
    return localRepository.countPending();
  }

  Future<int> countUploading() async {
    final low_level.LocalPackRepository localRepository = _requireRepository();
    return localRepository.countUploading();
  }

  Future<low_level.LocalPendingCaptureMetadata?> getPendingMetadata(
    String captureId,
  ) async {
    final low_level.LocalPackRepository localRepository = _requireRepository();
    return localRepository.getPendingMetadata(captureId);
  }

  Future<Map<String, Object?>?> decodePendingPayload(String captureId) async {
    final low_level.LocalPackRepository localRepository = _requireRepository();
    final Uint8List? gzipBytes = await localRepository.decryptById(captureId);
    if (gzipBytes == null) {
      return null;
    }
    final Object? decoded = jsonDecode(
      utf8.decode(gzip.decode(gzipBytes)),
    );
    if (decoded is! Map<Object?, Object?>) {
      throw StateError("Decoded payload must be an object map.");
    }
    return Map<String, Object?>.from(decoded);
  }

  Future<String> _ensureDatabasePath() async {
    final String? existingPath = _databasePath;
    if (existingPath != null) {
      return existingPath;
    }
    final Directory tempDirectory = await Directory.systemTemp.createTemp(
      "revclust_public_facade_capture_test_",
    );
    _tempDirectory = tempDirectory;
    final String createdPath = "${tempDirectory.path}/public_facade.db";
    _databasePath = createdPath;
    return createdPath;
  }

  Future<low_level.LocalPackRecord?> getById(String captureId) async {
    return _requireRepository().getById(captureId);
  }

  low_level.LocalPackRepository _requireRepository() {
    final low_level.LocalPackRepository? localRepository = repository;
    if (localRepository == null) {
      throw StateError("Local capture repository has not been created yet.");
    }
    return localRepository;
  }
}

final class _MemorySessionStateStore implements SessionStateStore {
  String? _lastSeenAppVersion;
  bool? _cleanShutdown;
  int? _lastCheckpointTimestampMs;

  @override
  Future<String?> readLastSeenAppVersion() async => _lastSeenAppVersion;

  @override
  Future<void> writeLastSeenAppVersion(String appVersion) async {
    _lastSeenAppVersion = appVersion;
  }

  @override
  Future<bool?> readCleanShutdown() async => _cleanShutdown;

  @override
  Future<void> writeCleanShutdown(bool value) async {
    _cleanShutdown = value;
  }

  @override
  Future<int?> readLastCheckpointTimestampMs() async =>
      _lastCheckpointTimestampMs;

  @override
  Future<void> writeLastCheckpointTimestampMs(int timestampMs) async {
    _lastCheckpointTimestampMs = timestampMs;
  }
}

final class SeededPendingCapture {
  const SeededPendingCapture({
    required this.result,
    this.metadata,
  });

  final low_level.PackBuildResult result;
  final low_level.LocalPendingCaptureMetadata? metadata;
}

final class TinyBudgetPackBuilder extends low_level.PackBuilder {
  @override
  low_level.PackBuildResult build(low_level.PackBuildRequest request) {
    return super.build(
      low_level.PackBuildRequest(
        captureEnvelope: request.captureEnvelope,
        sessionId: request.sessionId,
        updateContextSnapshot: request.updateContextSnapshot,
        appVersion: request.appVersion,
        build: request.build,
        deviceModel: request.deviceModel,
        osVersion: request.osVersion,
        networkType: request.networkType,
        appReleaseStage: request.appReleaseStage,
        rttBucket: request.rttBucket,
        quality: request.quality,
        gitSha: request.gitSha,
        appState: request.appState,
        dataState: request.dataState,
        maxPackBytesGzip: 1,
      ),
    );
  }
}

low_level.PackBuildResult buildSeededPackResult({
  required String captureId,
  String text = "seeded-pack",
}) {
  return low_level.PackBuildResult(
    payload: <String, Object?>{"capture_id": captureId},
    gzipBytes: Uint8List.fromList(utf8.encode(text)),
    truncated: false,
    droppedCountsByType: const <String, int>{},
    droppedBytes: 0,
  );
}

final class _StaticRuntimeConditionsProvider
    implements low_level.RuntimeConditionsProvider {
  const _StaticRuntimeConditionsProvider();

  @override
  Future<low_level.RuntimeConditionsSnapshot> resolve() async {
    return const low_level.RuntimeConditionsSnapshot(
      deviceModel: "Pixel 9 Pro",
      osVersion: "Android 16",
      networkType: "wifi",
    );
  }
}

low_level.RuntimeConditionsProvider _defaultRuntimeProviderFactory() {
  return const _StaticRuntimeConditionsProvider();
}

final class _TestLocalPackRepository extends low_level.LocalPackRepository {
  _TestLocalPackRepository({
    required super.encryptionService,
    required super.databasePath,
    required super.databaseFactory,
    required this.failPersistenceAfterBuild,
    required super.utcNowMs,
  });

  final bool failPersistenceAfterBuild;
  bool _applyRuntimeFailures = false;

  void enableRuntimePersistenceBehavior() {
    _applyRuntimeFailures = true;
  }

  @override
  Future<void> savePendingWithMetadata(
    low_level.PackBuildResult result, {
    low_level.LocalPendingCaptureMetadata? metadata,
  }) {
    if (_applyRuntimeFailures && failPersistenceAfterBuild) {
      throw StateError("simulated pending capture persistence failure");
    }
    return super.savePendingWithMetadata(
      result,
      metadata: metadata,
    );
  }
}
