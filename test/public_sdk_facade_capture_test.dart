import "dart:async";
import "dart:io";

import "package:dio/dio.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter_sdk/revclust_flutter.dart" as facade;
import "package:revclust_flutter_sdk/revclust_flutter_sdk.dart" as low_level;
import "package:revclust_flutter_sdk/src/public/revclust.dart"
    as facade_internal;
import "package:revclust_flutter_sdk/src/public/revclust_local_capture.dart"
    as local_capture_internal;
import "package:revclust_flutter_sdk/src/public/revclust_owned_upload.dart"
    as upload_internal;
import "package:revclust_flutter_sdk/src/state/state_snapshot.dart";

import "support/public_facade_local_capture_factory.dart";

const String _primaryProjectKey = "rpk_uC4n8XQvJ9tR2mLsY7pKdB3fW6zHaNe1";
const String _secondaryProjectKey = "rpk_M2pQ8dLx7YvN1kTr4HsJc9_wZa6BgFe2";

void main() {
  late TestPublicFacadeLocalCaptureFactory localCaptureFactory;

  setUp(() {
    facade_internal.RevclustFacadeTestSupport.reset();
    localCaptureFactory = TestPublicFacadeLocalCaptureFactory();
    facade_internal.RevclustFacadeTestSupport.localCaptureFactory =
        localCaptureFactory;
    facade_internal.RevclustFacadeTestSupport.uploadTransport =
        _HangingUploadTransport();
  });

  tearDown(() async {
    facade_internal.RevclustFacadeTestSupport.reset();
    await localCaptureFactory.dispose();
  });

  group("public facade capture", () {
    test(
        "capture in ready state builds the canonical pack and persists adjacent metadata",
        () async {
      final facade.Revclust revclust = await _initializeWithAssessment(
        _readyAssessment(),
      );
      revclust.setStateSnapshotProvider(
        () => const facade.RevclustStateSnapshot(
          appState: <String, Object?>{"screen": "confirmation"},
          dataState: <String, Object?>{"cart_id": "cart_123"},
        ),
      );

      final facade.RevclustTrigger trigger = _trigger();
      final facade.RevclustCaptureQueued queued =
          (await revclust.capture(trigger)) as facade.RevclustCaptureQueued;

      expect(queued.captureId, isNotEmpty);
      expect(
        revclust.uploadSnapshot.pendingCount +
            revclust.uploadSnapshot.uploadingCount,
        1,
      );
      expect(revclust.uploadSnapshot.lastErrorCode, isNull);
      expect(
        await localCaptureFactory.countPending() +
            await localCaptureFactory.countUploading(),
        1,
      );

      final low_level.LocalPendingCaptureMetadata? metadata =
          await localCaptureFactory.getPendingMetadata(queued.captureId);
      expect(metadata, isNotNull);
      expect(metadata!.identityKind, "order");
      expect(metadata.identityValue, "ord_123");
      expect(metadata.flow, "checkout");
      expect(metadata.screen, "confirmation");
      expect(metadata.stepLabel, "confirm_order");
      expect(
        metadata.reproHint,
        "Retry checkout after a slow confirmation poll.",
      );
      expect(metadata.relevantIds, <String, String>{"cart_id": "cart_123"});

      final Map<String, Object?>? payload =
          await localCaptureFactory.decodePendingPayload(queued.captureId);
      expect(payload, isNotNull);
      expect(payload!["capture_id"], queued.captureId);
      expect(payload["schema_version"], "1.0.0");

      final Map<String, Object?> triggerPayload = _asObjectMap(
        payload["trigger"],
      );
      expect(triggerPayload["reason"], trigger.reason);
      expect(triggerPayload["signature"], trigger.signature);
      expect(
        _asObjectMap(triggerPayload["identity"]),
        <String, Object?>{"kind": "order", "value": "ord_123"},
      );
      expect(triggerPayload["flow"], "checkout");
      expect(triggerPayload["screen"], "confirmation");
      expect(triggerPayload["step_label"], "confirm_order");
      expect(
        triggerPayload["repro_hint"],
        "Retry checkout after a slow confirmation poll.",
      );
      expect(
        _asObjectMap(triggerPayload["relevant_ids"]),
        <String, Object?>{"cart_id": "cart_123"},
      );
      expect(
        triggerPayload["expected"],
        <String, Object?>{"order_status": "confirmed"},
      );
      expect(
        triggerPayload["observed"],
        <String, Object?>{"order_status": "retrying"},
      );

      final Map<String, Object?> stateSnapshot = _asObjectMap(
        payload["state_snapshot"],
      );
      expect(
        _asObjectMap(stateSnapshot["app_state"]),
        <String, Object?>{"screen": "confirmation"},
      );
      expect(
        _asObjectMap(stateSnapshot["data_state"]),
        <String, Object?>{"cart_id": "cart_123"},
      );
    });

    test("public state snapshots are bounded and JSON-safe before pack build",
        () async {
      final facade.Revclust revclust = await _initializeWithAssessment(
        _readyAssessment(),
      );
      revclust.setStateSnapshotProvider(
        () => facade.RevclustStateSnapshot(
          appState: <String, Object?>{
            "screen": List<String>.filled(300, "s").join(),
            "unsupported": Object(),
            for (int index = 0; index < 40; index += 1) "k$index": "v$index",
          },
          dataState: <String, Object?>{
            "later": "not included after key cap",
          },
        ),
      );

      final facade.RevclustCaptureQueued queued =
          (await revclust.capture(_trigger())) as facade.RevclustCaptureQueued;
      final Map<String, Object?>? payload =
          await localCaptureFactory.decodePendingPayload(queued.captureId);
      expect(payload, isNotNull);

      final Map<String, Object?> stateSnapshot = _asObjectMap(
        payload!["state_snapshot"],
      );
      final Map<String, Object?> appState = _asObjectMap(
        stateSnapshot["app_state"],
      );
      final Map<String, Object?> dataState = _asObjectMap(
        stateSnapshot["data_state"],
      );

      expect(appState["screen"], List<String>.filled(256, "s").join());
      expect(appState.containsKey("unsupported"), isFalse);
      expect(appState.length + dataState.length, 32);
      expect(dataState, isEmpty);
    });

    test("captureManual queues locally through the same Slice 3 path",
        () async {
      final facade.Revclust revclust = await _initializeWithAssessment(
        _readyAssessment(),
      );

      final facade.RevclustCaptureQueued queued = (await revclust
          .captureManual(_trigger())) as facade.RevclustCaptureQueued;

      expect(queued.captureId, isNotEmpty);
      expect(
        revclust.uploadSnapshot.pendingCount +
            revclust.uploadSnapshot.uploadingCount,
        1,
      );
      expect(
        await localCaptureFactory.countPending() +
            await localCaptureFactory.countUploading(),
        1,
      );
    });

    test(
        "production desktop local capture queues through file fallback when secure storage is unavailable",
        () async {
      if (!(Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
        return;
      }

      final Directory tempDirectory = await Directory.systemTemp.createTemp(
        "revclust_public_facade_desktop_fallback_",
      );
      final local_capture_internal.DefaultRevclustFacadeLocalCaptureFactory
          productionFactory =
          local_capture_internal.DefaultRevclustFacadeLocalCaptureFactory(
        databaseDirectoryResolver: (_) async => tempDirectory.path,
        keyStoreFactory: (
          local_capture_internal.RevclustFacadeLocalStorageScope storageScope,
          String databasePath,
        ) {
          return low_level.DesktopPilotFallbackKeyStore(
            secureStorageKeyStore: _ThrowingUnavailableKeyStore(),
            fallbackKeyStore: low_level.FileBackedKeyStore(
              filePath: "$databasePath.key",
            ),
          );
        },
      );
      addTearDown(() async {
        facade_internal.RevclustFacadeTestSupport.reset();
        if (await tempDirectory.exists()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      facade_internal.RevclustFacadeTestSupport.reset();
      facade_internal.RevclustFacadeTestSupport.localCaptureFactory =
          productionFactory;
      facade_internal.RevclustFacadeTestSupport.uploadTransport =
          _HangingUploadTransport();

      final facade.Revclust revclust = await _initializeWithAssessment(
        _readyAssessment(),
      );

      final facade.RevclustCaptureOutcome outcome = await revclust.capture(
        _trigger(),
      );

      expect(outcome, isA<facade.RevclustCaptureQueued>());
      expect(
        revclust.uploadSnapshot.pendingCount +
            revclust.uploadSnapshot.uploadingCount,
        1,
      );

      final String databasePath =
          "${tempDirectory.path}/${facade_internal.RevclustFacadeTestSupport.localStorageDatabaseFileName(_config())}";
      final File keyFile = File("$databasePath.key");
      expect(await keyFile.exists(), isTrue);
      expect((await keyFile.readAsString()).trim(), isNotEmpty);
    });

    test(
        "capture still returns Queued when durable save succeeds but immediate snapshot refresh fails",
        () async {
      final TestPublicFacadeLocalCaptureFactory delegateFactory =
          localCaptureFactory;
      facade_internal.RevclustFacadeTestSupport.localCaptureFactory =
          _CountPendingFailureFacadeLocalCaptureFactory(
        delegateFactory,
        failingCountPendingCall: 3,
      );

      final facade.Revclust revclust = await _initializeWithAssessment(
        _readyAssessment(),
      );

      final facade.RevclustCaptureOutcome outcome = await revclust.capture(
        _trigger(),
      );

      expect(outcome, isA<facade.RevclustCaptureQueued>());
      expect(
        (outcome as facade.RevclustCaptureQueued).captureId,
        isNotEmpty,
      );
      expect(
        await delegateFactory.countPending() +
            await delegateFactory.countUploading(),
        1,
      );
    });

    test("pendingCount reflects seeded durable pending work on initialize",
        () async {
      facade_internal.RevclustFacadeTestSupport.reset();
      await localCaptureFactory.dispose();
      localCaptureFactory = TestPublicFacadeLocalCaptureFactory(
        seededPendingCaptures: <SeededPendingCapture>[
          SeededPendingCapture(
            result: buildSeededPackResult(captureId: "cap_seeded_001"),
            metadata: low_level.LocalPendingCaptureMetadata(
              captureId: "cap_seeded_001",
              identityKind: "order",
              identityValue: "ord_seeded",
              flow: "checkout",
            ),
          ),
        ],
      );
      facade_internal.RevclustFacadeTestSupport.localCaptureFactory =
          localCaptureFactory;

      final facade.Revclust revclust = await _initializeWithAssessment(
        _readyAssessment(),
      );

      expect(
        revclust.uploadSnapshot.pendingCount +
            revclust.uploadSnapshot.uploadingCount,
        1,
      );
      expect(
        await localCaptureFactory.countPending() +
            await localCaptureFactory.countUploading(),
        1,
      );
      final low_level.LocalPendingCaptureMetadata? metadata =
          await localCaptureFactory.getPendingMetadata("cap_seeded_001");
      expect(metadata, isNotNull);
      expect(metadata!.identityValue, "ord_seeded");
      expect(metadata.flow, "checkout");
    });

    test("build failures return BuildFailed and do not queue pending work",
        () async {
      facade_internal.RevclustFacadeTestSupport.reset();
      await localCaptureFactory.dispose();
      localCaptureFactory = TestPublicFacadeLocalCaptureFactory(
        runtimeConditionsProviderFactory:
            _ThrowingRuntimeConditionsProvider.new,
      );
      facade_internal.RevclustFacadeTestSupport.localCaptureFactory =
          localCaptureFactory;

      final facade.Revclust revclust = await _initializeWithAssessment(
        _readyAssessment(),
      );

      final facade.RevclustCaptureBuildFailed failed = (await revclust
          .capture(_trigger())) as facade.RevclustCaptureBuildFailed;

      expect(failed.captureId, isNotEmpty);
      expect(failed.message, isNotEmpty);
      expect(revclust.uploadSnapshot.pendingCount, 0);
      expect(await localCaptureFactory.countPending(), 0);
    });

    test(
        "persistence failures return PersistenceFailed and do not masquerade as build failures",
        () async {
      facade_internal.RevclustFacadeTestSupport.reset();
      await localCaptureFactory.dispose();
      localCaptureFactory = TestPublicFacadeLocalCaptureFactory(
        failPersistenceAfterBuild: true,
      );
      facade_internal.RevclustFacadeTestSupport.localCaptureFactory =
          localCaptureFactory;

      final facade.Revclust revclust = await _initializeWithAssessment(
        _readyAssessment(),
      );

      final facade.RevclustCaptureOutcome outcome = await revclust.capture(
        _trigger(),
      );

      expect(outcome, isA<facade.RevclustCapturePersistenceFailed>());
      final facade.RevclustCapturePersistenceFailed failed =
          outcome as facade.RevclustCapturePersistenceFailed;
      expect(failed.captureId, isNotEmpty);
      expect(failed.message, contains("persistence failed"));
      expect(revclust.uploadSnapshot.pendingCount, 0);
      expect(await localCaptureFactory.countPending(), 0);
    });

    test("local storage scope changes across project keys in one environment",
        () {
      final String firstDatabaseFileName = facade_internal
          .RevclustFacadeTestSupport.localStorageDatabaseFileName(
        _config(projectKey: _primaryProjectKey),
      );
      final String secondDatabaseFileName = facade_internal
          .RevclustFacadeTestSupport.localStorageDatabaseFileName(
        _config(projectKey: _secondaryProjectKey),
      );
      final String firstStorageKey =
          facade_internal.RevclustFacadeTestSupport.localStorageKey(
        _config(projectKey: _primaryProjectKey),
      );
      final String secondStorageKey =
          facade_internal.RevclustFacadeTestSupport.localStorageKey(
        _config(projectKey: _secondaryProjectKey),
      );

      expect(firstDatabaseFileName, isNot(secondDatabaseFileName));
      expect(firstStorageKey, isNot(secondStorageKey));
      expect(
        firstDatabaseFileName,
        contains(facade.RevclustEnvironment.staging.name),
      );
      expect(
        secondStorageKey,
        contains(facade.RevclustEnvironment.staging.name),
      );
    });
  });
}

facade.RevclustConfig _config({
  String projectKey = _primaryProjectKey,
  facade.RevclustEnvironment environment = facade.RevclustEnvironment.staging,
}) {
  return facade.RevclustConfig(
    projectKey: projectKey,
    environment: environment,
  );
}

Future<facade.Revclust> _initializeWithAssessment(
  facade_internal.RevclustBootstrapAssessment assessment,
) {
  facade_internal.RevclustFacadeTestSupport.bootstrapProbe =
      _FakeBootstrapProbe((_) async => assessment);
  return facade.Revclust.initialize(_config());
}

facade_internal.RevclustBootstrapAssessment _readyAssessment() {
  return facade_internal.RevclustBootstrapAssessment.ready(
    lease: facade_internal.RevclustBootstrapLease(
      uploadEndpoint: Uri.parse("https://revclust.com/api/pilot/packs"),
      authToken: "pilot_upload_auth_live",
      usableUntil: DateTime.parse("2030-01-01T00:00:00Z"),
      viewerBaseUrl: Uri.parse("https://revclust.com/pilot/packs"),
    ),
  );
}

facade.RevclustTrigger _trigger() {
  return facade.RevclustTrigger(
    reason: "checkout confirmation mismatch",
    expected: <String, Object?>{"order_status": "confirmed"},
    observed: <String, Object?>{"order_status": "retrying"},
    identity: facade.RevclustIdentity(
      kind: "order",
      value: "ord_123",
    ),
    signature: "checkout_confirmation_mismatch",
    flow: "checkout",
    screen: "confirmation",
    stepLabel: "confirm_order",
    reproHint: "Retry checkout after a slow confirmation poll.",
    relevantIds: const <String, String>{"cart_id": "cart_123"},
  );
}

Map<String, Object?> _asObjectMap(Object? value) {
  if (value is Map<Object?, Object?>) {
    return Map<String, Object?>.from(value);
  }
  throw StateError("Expected object map.");
}

final class _FakeBootstrapProbe
    implements facade_internal.RevclustBootstrapProbe {
  _FakeBootstrapProbe(this._assess);

  final Future<facade_internal.RevclustBootstrapAssessment> Function(
    facade.RevclustConfig config,
  ) _assess;

  @override
  Future<facade_internal.RevclustBootstrapAssessment> assess(
    facade.RevclustConfig config,
  ) {
    return _assess(config);
  }
}

final class _ThrowingRuntimeConditionsProvider
    implements low_level.RuntimeConditionsProvider {
  @override
  Future<low_level.RuntimeConditionsSnapshot> resolve() async {
    throw StateError("simulated runtime conditions failure");
  }
}

final class _CountPendingFailureFacadeLocalCaptureFactory
    implements local_capture_internal.RevclustFacadeLocalCaptureFactory {
  _CountPendingFailureFacadeLocalCaptureFactory(
    this._delegate, {
    required this.failingCountPendingCall,
  });

  final local_capture_internal.RevclustFacadeLocalCaptureFactory _delegate;
  final int failingCountPendingCall;

  @override
  Future<local_capture_internal.RevclustFacadeLocalCapture> create(
    facade.RevclustConfig config,
  ) async {
    return _CountPendingFailureFacadeLocalCapture(
      await _delegate.create(config),
      failingCountPendingCall: failingCountPendingCall,
    );
  }
}

final class _CountPendingFailureFacadeLocalCapture
    implements local_capture_internal.RevclustFacadeLocalCapture {
  _CountPendingFailureFacadeLocalCapture(
    this._delegate, {
    required this.failingCountPendingCall,
  });

  final local_capture_internal.RevclustFacadeLocalCapture _delegate;
  final int failingCountPendingCall;
  int _countPendingCalls = 0;

  @override
  low_level.LocalPackRepository get repository => _delegate.repository;

  @override
  Future<facade.RevclustCaptureOutcome> capture(
    facade.RevclustTrigger trigger, {
    required bool manual,
  }) {
    return _delegate.capture(trigger, manual: manual);
  }

  @override
  Future<int> countPending() async {
    _countPendingCalls++;
    if (_countPendingCalls == failingCountPendingCall) {
      throw StateError("simulated upload snapshot refresh failure");
    }
    return _delegate.countPending();
  }

  @override
  Future<void> dispose() => _delegate.dispose();

  @override
  void enableDioCapture(Dio dio) {
    _delegate.enableDioCapture(dio);
  }

  @override
  void setStateSnapshotProvider(StateSnapshot Function()? provider) {
    _delegate.setStateSnapshotProvider(provider);
  }
}

final class _HangingUploadTransport
    implements upload_internal.RevclustOwnedUploadTransport {
  final Completer<upload_internal.RevclustOwnedUploadTransportResult>
      _completer =
      Completer<upload_internal.RevclustOwnedUploadTransportResult>();

  @override
  Future<upload_internal.RevclustOwnedUploadTransportResult> upload({
    required low_level.LocalPackRecord claimedPack,
    required facade_internal.RevclustBootstrapLease lease,
  }) {
    return _completer.future;
  }
}

final class _ThrowingUnavailableKeyStore implements low_level.KeyStore {
  @override
  Future<Uint8List?> readKeyMaterial() async {
    throw PlatformException(
      code: "libsecret_error",
      message: "Failed to unlock the keyring",
    );
  }

  @override
  Future<void> writeKeyMaterial(Uint8List keyMaterial) async {
    throw PlatformException(
      code: "libsecret_error",
      message: "Failed to unlock the keyring",
    );
  }
}
