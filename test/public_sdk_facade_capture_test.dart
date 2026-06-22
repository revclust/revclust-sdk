import "dart:async";
import "dart:io";

import "package:dio/dio.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter_sdk/revclust_flutter.dart" as facade;
import "package:revclust_flutter_sdk/src/internal/revclust_internal.dart"
    as low_level;
import "package:revclust_flutter_sdk/src/public/revclust.dart"
    as facade_internal;
import "package:revclust_flutter_sdk/src/public/revclust_local_capture.dart"
    as local_capture_internal;
import "package:revclust_flutter_sdk/src/public/revclust_owned_upload.dart"
    as upload_internal;
import "package:revclust_flutter_sdk/src/state/state_snapshot.dart";

import "support/public_facade_local_capture_factory.dart";

// Deliberately synthetic shape-valid test keys; never provision these.
const String _primaryProjectKey = "rpk_00000000000000000000000000000000";
const String _secondaryProjectKey = "rpk_11111111111111111111111111111111";

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

      final facade.RevclustInvariantFailure failure = _failure();
      final facade.RevclustCaptureQueued queued = (await revclust
          .captureInvariantFailure(failure)) as facade.RevclustCaptureQueued;

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
      expect(metadata!.failureKind, "checkout_confirmation_mismatch");
      expect(metadata.subjectKind, "order_ref");
      expect(metadata.subjectValue, "ord_123");

      final Map<String, Object?>? payload =
          await localCaptureFactory.decodePendingPayload(queued.captureId);
      expect(payload, isNotNull);
      expect(payload!["capture_id"], queued.captureId);
      expect(payload["schema_version"], "1.0.0");
      expect(
        _asObjectMap(payload["conditions"])["app_release_stage"],
        "staging",
      );
      expect(_asObjectMap(payload["conditions"])["app_version"], "1.2.3");
      expect(_asObjectMap(payload["conditions"])["build"], "1203");
      expect(_asObjectMap(payload["conditions"])["git_sha"], "abcdef1");
      expect(
        _asObjectMap(_asObjectMap(payload["conditions"])["update_context"]),
        <String, Object?>{
          "is_first_run_after_update": false,
          "prev_app_version": null,
          "install_type": "fresh_install",
        },
      );

      final Map<String, Object?> triggerPayload = _asObjectMap(
        payload["trigger"],
      );
      expect(triggerPayload["type"], "invariant_failure");
      expect(triggerPayload["failure_kind"], failure.failureKind);
      expect(
        _asObjectMap(triggerPayload["subject"]),
        <String, Object?>{"kind": "order_ref", "value": "ord_123"},
      );
      expect(triggerPayload.containsKey("reason"), isFalse);
      expect(triggerPayload.containsKey("signature"), isFalse);
      expect(triggerPayload.containsKey("identity"), isFalse);
      expect(triggerPayload.containsKey("flow"), isFalse);
      expect(triggerPayload.containsKey("screen"), isFalse);
      expect(triggerPayload.containsKey("step_label"), isFalse);
      expect(triggerPayload.containsKey("relevant_ids"), isFalse);
      expect(triggerPayload.containsKey("repro_hint"), isFalse);
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

    test("reviewed timeline breadcrumbs are captured in pre-trigger order",
        () async {
      final facade.Revclust revclust = await _initializeWithAssessment(
        _readyAssessment(),
      );

      revclust.recordUiIntent(
        name: "book_selected",
        attributes: const <String, Object?>{
          "catalog_segment": "popular",
          "book_ref": "book_ref_123",
        },
      );
      revclust.recordScreenTransition(
        fromScreen: "books.popular",
        toScreen: "book_details",
        attributes: const <String, Object?>{"book_ref": "book_ref_123"},
      );

      final facade.RevclustCaptureQueued queued = (await revclust
          .captureInvariantFailure(_failure())) as facade.RevclustCaptureQueued;
      final Map<String, Object?>? payload =
          await localCaptureFactory.decodePendingPayload(queued.captureId);
      expect(payload, isNotNull);

      final List<Object?> timeline = _asObjectList(payload!["timeline"]);
      expect(timeline, hasLength(2));

      final Map<String, Object?> selected = _asObjectMap(timeline[0]);
      expect(selected["event_type"], "ui.intent");
      expect(selected["t_mono_ms"], isA<int>());
      expect(selected["name"], "book_selected");
      expect(selected["catalog_segment"], "popular");
      expect(selected["book_ref"], "book_ref_123");

      final Map<String, Object?> transition = _asObjectMap(timeline[1]);
      expect(transition["event_type"], "ui.screen_transition");
      expect(transition["t_mono_ms"], isA<int>());
      expect(transition["from"], "books.popular");
      expect(transition["to"], "book_details");
      expect(transition["book_ref"], "book_ref_123");
    });

    test("reviewed timeline breadcrumbs are best effort and bounded", () async {
      final facade.Revclust revclust = await _initializeWithAssessment(
        _readyAssessment(),
      );

      expect(
        () => revclust.recordUiIntent(name: "   "),
        returnsNormally,
      );
      expect(
        () => revclust.recordScreenTransition(
          fromScreen: "books.popular",
          toScreen: " ",
        ),
        returnsNormally,
      );

      revclust.recordUiIntent(
        name: "  book_selected  ",
        attributes: <String, Object?>{
          " catalog_segment ": "popular",
          "long_string": List<String>.filled(300, "x").join(),
          "unsupported": Object(),
          "nan": double.nan,
          "duplicate": "first",
          " duplicate ": "second",
          "nested": <Object?, Object?>{
            " child ": "value",
            7: "dropped",
            "": "dropped",
            "unsupported": Object(),
          },
          "list": <Object?>["ok", Object(), null, double.infinity, false],
          "too_large": List<String>.filled(
            40,
            List<String>.filled(256, "z").join(),
          ),
          for (int index = 0; index < 20; index += 1) "k$index": "v$index",
        },
      );

      final facade.RevclustCaptureQueued queued = (await revclust
          .captureInvariantFailure(_failure())) as facade.RevclustCaptureQueued;
      final Map<String, Object?>? payload =
          await localCaptureFactory.decodePendingPayload(queued.captureId);
      expect(payload, isNotNull);

      final List<Object?> timeline = _asObjectList(payload!["timeline"]);
      expect(timeline, hasLength(1));
      final Map<String, Object?> entry = _asObjectMap(timeline.single);

      expect(entry["event_type"], "ui.intent");
      expect(entry["name"], "book_selected");
      expect(entry["catalog_segment"], "popular");
      expect(entry["long_string"], List<String>.filled(256, "x").join());
      expect(entry["unsupported"], isNull);
      expect(entry.containsKey("unsupported"), isFalse);
      expect(entry.containsKey("nan"), isFalse);
      expect(entry["duplicate"], "first");
      expect(
        _asObjectMap(entry["nested"]),
        <String, Object?>{"child": "value"},
      );
      expect(_asObjectList(entry["list"]), <Object?>["ok", null, false]);
      expect(entry.containsKey("too_large"), isFalse);
      expect(entry["k10"], "v10");
      expect(entry.containsKey("k11"), isFalse);

      facade_internal.RevclustFacadeTestSupport.reset();
      expect(
        () => revclust.recordUiIntent(name: "after_dispose"),
        returnsNormally,
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

      final facade.RevclustCaptureQueued queued = (await revclust
          .captureInvariantFailure(_failure())) as facade.RevclustCaptureQueued;
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

    test("captureInvariantFailure queues locally through the Slice 3 path",
        () async {
      final facade.Revclust revclust = await _initializeWithAssessment(
        _readyAssessment(),
      );

      final facade.RevclustCaptureQueued queued = (await revclust
          .captureInvariantFailure(_failure())) as facade.RevclustCaptureQueued;

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

      final facade.RevclustCaptureOutcome outcome =
          await revclust.captureInvariantFailure(
        _failure(),
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

      final facade.RevclustCaptureOutcome outcome =
          await revclust.captureInvariantFailure(
        _failure(),
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
              failureKind: "checkout_confirmation_mismatch",
              subjectKind: "order_ref",
              subjectValue: "ord_seeded",
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
      expect(metadata!.failureKind, "checkout_confirmation_mismatch");
      expect(metadata.subjectKind, "order_ref");
      expect(metadata.subjectValue, "ord_seeded");
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

      final facade.RevclustCaptureBuildFailed failed =
          (await revclust.captureInvariantFailure(_failure()))
              as facade.RevclustCaptureBuildFailed;

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

      final facade.RevclustCaptureOutcome outcome =
          await revclust.captureInvariantFailure(
        _failure(),
      );

      expect(outcome, isA<facade.RevclustCapturePersistenceFailed>());
      final facade.RevclustCapturePersistenceFailed failed =
          outcome as facade.RevclustCapturePersistenceFailed;
      expect(failed.captureId, isNotEmpty);
      expect(failed.message, contains("persistence failed"));
      expect(revclust.uploadSnapshot.pendingCount, 0);
      expect(await localCaptureFactory.countPending(), 0);
    });

    test("local storage scope changes across project keys", () {
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
      expect(firstDatabaseFileName, isNot(contains("staging")));
      expect(secondStorageKey, isNot(contains("staging")));
    });

    test("omitted build metadata preserves unknown condition fallbacks",
        () async {
      final facade.Revclust revclust = await _initializeWithAssessment(
        _readyAssessment(),
        config: facade.RevclustConfig(projectKey: _primaryProjectKey),
      );

      final facade.RevclustCaptureQueued queued = (await revclust
          .captureInvariantFailure(_failure())) as facade.RevclustCaptureQueued;
      final Map<String, Object?>? payload =
          await localCaptureFactory.decodePendingPayload(queued.captureId);
      final Map<String, Object?> conditions = _asObjectMap(
        payload!["conditions"],
      );

      expect(conditions["app_version"], "unknown");
      expect(conditions["build"], "unknown");
      expect(conditions.containsKey("git_sha"), isFalse);
    });
  });
}

facade.RevclustConfig _config({
  String projectKey = _primaryProjectKey,
  facade.RevclustAppReleaseStage? releaseStage =
      facade.RevclustAppReleaseStage.staging,
  String? appVersion = "1.2.3",
  String? build = "1203",
  String? gitSha = "ABCDEF1",
}) {
  return facade.RevclustConfig(
    projectKey: projectKey,
    releaseStage: releaseStage,
    appVersion: appVersion,
    build: build,
    gitSha: gitSha,
  );
}

Future<facade.Revclust> _initializeWithAssessment(
    facade_internal.RevclustBootstrapAssessment assessment,
    {facade.RevclustConfig? config}) {
  facade_internal.RevclustFacadeTestSupport.bootstrapProbe =
      _FakeBootstrapProbe((_) async => assessment);
  return facade.Revclust.initialize(config ?? _config());
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

facade.RevclustInvariantFailure _failure() {
  return facade.RevclustInvariantFailure(
    failureKind: "checkout_confirmation_mismatch",
    subject: facade.RevclustSubject(
      kind: "order_ref",
      value: "ord_123",
    ),
    expected: <String, Object?>{"order_status": "confirmed"},
    observed: <String, Object?>{"order_status": "retrying"},
  );
}

Map<String, Object?> _asObjectMap(Object? value) {
  if (value is Map<Object?, Object?>) {
    return Map<String, Object?>.from(value);
  }
  throw StateError("Expected object map.");
}

List<Object?> _asObjectList(Object? value) {
  if (value is List<Object?>) {
    return value;
  }
  if (value is List<dynamic>) {
    return List<Object?>.from(value);
  }
  throw StateError("Expected object list.");
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
  Future<facade.RevclustCaptureOutcome> captureInvariantFailure(
    facade.RevclustInvariantFailure failure,
  ) {
    return _delegate.captureInvariantFailure(failure);
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
  void recordScreenTransition({
    required String fromScreen,
    required String toScreen,
    Map<String, Object?> attributes = const <String, Object?>{},
  }) {
    _delegate.recordScreenTransition(
      fromScreen: fromScreen,
      toScreen: toScreen,
      attributes: attributes,
    );
  }

  @override
  void recordUiIntent({
    required String name,
    Map<String, Object?> attributes = const <String, Object?>{},
  }) {
    _delegate.recordUiIntent(name: name, attributes: attributes);
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
