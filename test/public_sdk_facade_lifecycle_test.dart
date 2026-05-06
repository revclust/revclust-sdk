import "dart:async";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter_sdk/revclust_flutter.dart" as facade;
import "package:revclust_flutter_sdk/revclust_flutter_sdk.dart" as low_level;
import "package:revclust_flutter_sdk/src/public/revclust.dart"
    as facade_internal;
import "package:revclust_flutter_sdk/src/public/revclust_owned_upload.dart"
    as upload_internal;

import "support/public_facade_local_capture_factory.dart";

const String _defaultProjectKey = "rpk_uC4n8XQvJ9tR2mLsY7pKdB3fW6zHaNe1";
const String _firstProjectKey = "rpk_Q7mN2xLd8KpR4vTsc1Jw9_yBh5DfGzA3";
const String _recoveredProjectKey = "rpk_M2pQ8dLx7YvN1kTr4HsJc9_wZa6BgFe2";
const String _conflictingProjectKey = "rpk_V9qL3nWx2TbK7mRsd4HjC8_aYp6FgZe1";

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

  group("public facade lifecycle", () {
    test(
        "starts disabled and stays visibly initializing until bootstrap resolves",
        () async {
      final Completer<facade_internal.RevclustBootstrapAssessment> completer =
          Completer<facade_internal.RevclustBootstrapAssessment>();
      facade_internal.RevclustFacadeTestSupport.bootstrapProbe =
          _FakeBootstrapProbe((_) => completer.future);

      expect(
        facade_internal.RevclustFacadeTestSupport.lifecycleState,
        isA<facade_internal.RevclustFacadeDisabled>(),
      );

      final Future<facade.Revclust> initializeFuture =
          facade.Revclust.initialize(
        _config(),
      );

      expect(
        facade_internal.RevclustFacadeTestSupport.lifecycleState,
        isA<facade_internal.RevclustFacadeInitializing>(),
      );
      expect(
        facade_internal.RevclustFacadeTestSupport.currentFacade?.status,
        facade.RevclustStatus.initializing,
      );

      completer.complete(_readyAssessment());

      final facade.Revclust revclust = await initializeFuture;
      expect(revclust.status, facade.RevclustStatus.ready);
      expect(
        facade_internal.RevclustFacadeTestSupport.lifecycleState,
        isA<facade_internal.RevclustFacadeReady>(),
      );
    });

    test("same-config concurrent init resolves through one future and facade",
        () async {
      final Completer<facade_internal.RevclustBootstrapAssessment> completer =
          Completer<facade_internal.RevclustBootstrapAssessment>();
      facade_internal.RevclustFacadeTestSupport.bootstrapProbe =
          _FakeBootstrapProbe((_) => completer.future);

      final facade.RevclustConfig config = _config();
      final Future<facade.Revclust> first = facade.Revclust.initialize(config);
      final Future<facade.Revclust> second = facade.Revclust.initialize(config);

      expect(identical(first, second), isTrue);

      completer.complete(_readyAssessment());

      final facade.Revclust firstFacade = await first;
      final facade.Revclust secondFacade = await second;

      expect(firstFacade, same(secondFacade));
      expect(firstFacade.status, facade.RevclustStatus.ready);
    });

    test(
        "local-capture init failure leaves visible degraded state and same-config retry can recover",
        () async {
      facade_internal.RevclustFacadeTestSupport.reset();
      await localCaptureFactory.dispose();
      localCaptureFactory = TestPublicFacadeLocalCaptureFactory(
        failingCreateAttempts: 1,
      );
      facade_internal.RevclustFacadeTestSupport.localCaptureFactory =
          localCaptureFactory;
      facade_internal.RevclustFacadeTestSupport.bootstrapProbe =
          _FakeBootstrapProbe(
        (_) async => _readyAssessment(),
      );

      await expectLater(
        facade.Revclust.initialize(_config()),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.toString(),
            "message",
            contains("local capture initialization failed"),
          ),
        ),
      );

      final facade_internal.RevclustFacadeLifecycleState failedState =
          facade_internal.RevclustFacadeTestSupport.lifecycleState;
      expect(
        failedState,
        isA<facade_internal.RevclustFacadeLocalCaptureUnavailable>(),
      );
      expect(failedState.status, facade.RevclustStatus.degraded);
      expect(
        failedState.message,
        contains("simulated local capture initialization failure"),
      );
      expect(facade_internal.RevclustFacadeTestSupport.currentFacade, isNull);
      expect(localCaptureFactory.createCallCount, 1);

      final facade.Revclust revclust = await facade.Revclust.initialize(
        _config(),
      );

      expect(localCaptureFactory.createCallCount, 2);
      expect(revclust.status, facade.RevclustStatus.ready);
      expect(
        facade_internal.RevclustFacadeTestSupport.lifecycleState,
        isA<facade_internal.RevclustFacadeReady>(),
      );
    });

    test(
        "failed local-capture init clears stale config so a different config can initialize later",
        () async {
      facade_internal.RevclustFacadeTestSupport.reset();
      await localCaptureFactory.dispose();
      localCaptureFactory = TestPublicFacadeLocalCaptureFactory(
        failingCreateAttempts: 1,
      );
      facade_internal.RevclustFacadeTestSupport.localCaptureFactory =
          localCaptureFactory;
      facade_internal.RevclustFacadeTestSupport.bootstrapProbe =
          _FakeBootstrapProbe(
        (_) async => _readyAssessment(),
      );

      await expectLater(
        facade.Revclust.initialize(_config(projectKey: _firstProjectKey)),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.toString(),
            "message",
            contains("local capture initialization failed"),
          ),
        ),
      );

      final facade.Revclust recoveredFacade = await facade.Revclust.initialize(
        _config(projectKey: _recoveredProjectKey),
      );

      expect(localCaptureFactory.createCallCount, 2);
      expect(recoveredFacade.status, facade.RevclustStatus.ready);
      expect(
        facade_internal.RevclustFacadeTestSupport.lifecycleState,
        isA<facade_internal.RevclustFacadeReady>().having(
          (facade_internal.RevclustFacadeReady state) =>
              state.config?.projectKey,
          "projectKey",
          _recoveredProjectKey,
        ),
      );
    });

    test("conflicting init fails clearly during active initialization",
        () async {
      final Completer<facade_internal.RevclustBootstrapAssessment> completer =
          Completer<facade_internal.RevclustBootstrapAssessment>();
      facade_internal.RevclustFacadeTestSupport.bootstrapProbe =
          _FakeBootstrapProbe((_) => completer.future);

      final Future<facade.Revclust> initializeFuture =
          facade.Revclust.initialize(
        _config(),
      );

      await expectLater(
        facade.Revclust.initialize(
          _config(projectKey: _conflictingProjectKey),
        ),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.toString(),
            "message",
            contains("conflicting initialize"),
          ),
        ),
      );

      completer.complete(
        _readyAssessment(),
      );
      await initializeFuture;
    });

    test("conflicting init fails clearly after initialization completes",
        () async {
      await facade.Revclust.initialize(_config());

      await expectLater(
        facade.Revclust.initialize(
          _config(projectKey: _conflictingProjectKey),
        ),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.toString(),
            "message",
            contains("conflicting initialize"),
          ),
        ),
      );
    });

    test("ready facade exposes real baseline service-health surfaces",
        () async {
      final facade.Revclust revclust = await _initializeWithAssessment(
        _readyAssessment(),
      );

      expect(revclust.status, facade.RevclustStatus.ready);
      expect(revclust.uploadSnapshot.pendingCount, 0);
      expect(revclust.uploadSnapshot.uploadingCount, 0);
      expect(revclust.uploadSnapshot.lastErrorCode, isNull);
      expect(revclust.uploadEvents.isBroadcast, isTrue);
    });

    test(
        "bootstrap unavailable stays degraded while local capture still queues",
        () async {
      final facade.Revclust revclust = await _initializeWithAssessment(
        const facade_internal.RevclustBootstrapAssessment.bootstrapUnavailable(
          message: "Bootstrap is unavailable.",
        ),
      );

      expect(revclust.status, facade.RevclustStatus.degraded);
      expect(
        revclust.uploadSnapshot.lastErrorCode,
        facade.RevclustUploadErrorCode.transportUnavailable,
      );

      final facade.RevclustCaptureQueued queued =
          (await revclust.capture(_trigger())) as facade.RevclustCaptureQueued;

      expect(queued.captureId, isNotEmpty);
      expect(revclust.status, facade.RevclustStatus.degraded);
      expect(revclust.uploadSnapshot.pendingCount, 1);
      expect(
        revclust.uploadSnapshot.lastErrorCode,
        facade.RevclustUploadErrorCode.transportUnavailable,
      );
    });

    test("misconfigured bootstrap stays visible and blocks manual capture",
        () async {
      final facade.Revclust revclust = await _initializeWithAssessment(
        const facade_internal.RevclustBootstrapAssessment.misconfigured(
          message: "Project key is misconfigured.",
        ),
      );

      expect(revclust.status, facade.RevclustStatus.misconfigured);
      expect(
        revclust.uploadSnapshot.lastErrorCode,
        facade.RevclustUploadErrorCode.misconfiguration,
      );

      final facade.RevclustCaptureBlocked blocked = (await revclust
          .captureManual(_trigger())) as facade.RevclustCaptureBlocked;

      expect(blocked.status, facade.RevclustStatus.misconfigured);
      expect(blocked.message, contains("misconfigured"));
    });

    test("not provisioned bootstrap stays visible and blocks capture",
        () async {
      final facade.Revclust revclust = await _initializeWithAssessment(
        const facade_internal.RevclustBootstrapAssessment.notProvisioned(
          message: "Project key is not provisioned.",
        ),
      );

      expect(revclust.status, facade.RevclustStatus.notProvisioned);
      expect(
        revclust.uploadSnapshot.lastErrorCode,
        facade.RevclustUploadErrorCode.misconfiguration,
      );

      final facade.RevclustCaptureBlocked blocked =
          (await revclust.capture(_trigger())) as facade.RevclustCaptureBlocked;

      expect(blocked.status, facade.RevclustStatus.notProvisioned);
      expect(blocked.message, contains("not provisioned"));
    });

    test("uploadBlocked stays visible while local queueing remains allowed",
        () async {
      final facade.Revclust revclust = await _initializeWithAssessment(
        const facade_internal.RevclustBootstrapAssessment.uploadBlocked(
          message: "Upload auth is currently unavailable.",
        ),
      );

      expect(revclust.status, facade.RevclustStatus.uploadBlocked);
      expect(
        revclust.uploadSnapshot.lastErrorCode,
        facade.RevclustUploadErrorCode.auth,
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
      expect(
        revclust.uploadSnapshot.lastErrorCode,
        facade.RevclustUploadErrorCode.auth,
      );
    });

    test("ready bootstrap allows real local capture queueing", () async {
      final facade.Revclust revclust = await _initializeWithAssessment(
        _readyAssessment(),
      );

      final facade.RevclustCaptureQueued queued =
          (await revclust.capture(_trigger())) as facade.RevclustCaptureQueued;

      expect(queued.captureId, isNotEmpty);
      expect(revclust.status, facade.RevclustStatus.ready);
      expect(
        revclust.uploadSnapshot.pendingCount +
            revclust.uploadSnapshot.uploadingCount,
        1,
      );
      expect(revclust.uploadSnapshot.lastErrorCode, isNull);
    });

    test("ready bootstrap still reports initializing capture as blocked",
        () async {
      final Completer<facade_internal.RevclustBootstrapAssessment> completer =
          Completer<facade_internal.RevclustBootstrapAssessment>();
      facade_internal.RevclustFacadeTestSupport.bootstrapProbe =
          _FakeBootstrapProbe((_) => completer.future);

      final Future<facade.Revclust> initializeFuture =
          facade.Revclust.initialize(
        _config(),
      );
      final facade.Revclust revclust =
          facade_internal.RevclustFacadeTestSupport.currentFacade!;

      final facade.RevclustCaptureBlocked blocked =
          (await revclust.capture(_trigger())) as facade.RevclustCaptureBlocked;

      expect(blocked.status, facade.RevclustStatus.initializing);
      expect(blocked.message, contains("initializing"));

      completer.complete(
        _readyAssessment(),
      );
      await initializeFuture;
    });

    test("hook methods store honest facade-local configuration only", () async {
      final facade.Revclust revclust = await _initializeWithAssessment(
        _readyAssessment(),
      );
      final Dio dio = Dio();

      revclust.enableDioCapture(dio);
      revclust.enableDioCapture(dio);
      revclust.setStateSnapshotProvider(
        () => const facade.RevclustStateSnapshot(
          appState: <String, Object?>{"screen": "checkout"},
        ),
      );
      revclust.enableUnhandledExceptionCapture();
      revclust.enableUnhandledExceptionCapture();

      final facade_internal.RevclustFacadeDebugSnapshot snapshot =
          facade_internal.RevclustFacadeTestSupport.snapshot(revclust);

      expect(
          snapshot.lifecycleState, isA<facade_internal.RevclustFacadeReady>());
      expect(snapshot.registeredDioCount, 1);
      expect(snapshot.hasStateSnapshotProvider, isTrue);
      expect(snapshot.unhandledExceptionCaptureEnabled, isTrue);
    });
  });
}

facade.RevclustConfig _config({
  String projectKey = _defaultProjectKey,
  facade.RevclustEnvironment environment = facade.RevclustEnvironment.staging,
}) {
  return facade.RevclustConfig(
    projectKey: projectKey,
    environment: environment,
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
