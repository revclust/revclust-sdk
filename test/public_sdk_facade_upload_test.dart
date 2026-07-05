import "dart:async";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter_sdk/revclust_flutter.dart" as facade;
import "package:revclust_flutter_sdk/src/internal/revclust_internal.dart"
    as low_level;
import "package:revclust_flutter_sdk/src/public/revclust_bootstrap.dart"
    as bootstrap_internal;
import "package:revclust_flutter_sdk/src/public/revclust.dart"
    as facade_internal;
import "package:revclust_flutter_sdk/src/public/revclust_owned_upload.dart"
    as upload_internal;
import "package:sqflite_common_ffi/sqflite_ffi.dart";

import "support/in_memory_key_store.dart";
import "support/public_facade_local_capture_factory.dart";

// Deliberately synthetic shape-valid test keys; never provision these.
const String _defaultProjectKey = "rpk_00000000000000000000000000000000";
const String _misconfiguredProjectKey = "rpk_11111111111111111111111111111111";
const String _missingProjectKey = "rpk_22222222222222222222222222222222";

void main() {
  late int clockMs;
  late TestPublicFacadeLocalCaptureFactory localCaptureFactory;

  setUp(() {
    clockMs = 1000;
    facade_internal.RevclustFacadeTestSupport.reset();
    localCaptureFactory = TestPublicFacadeLocalCaptureFactory(
      utcNowMs: () => clockMs,
    );
    facade_internal.RevclustFacadeTestSupport.localCaptureFactory =
        localCaptureFactory;
    facade_internal.RevclustFacadeTestSupport.utcNow = _utcNowFactory(
      () => clockMs,
    );
  });

  tearDown(() async {
    facade_internal.RevclustFacadeTestSupport.reset();
    await localCaptureFactory.dispose();
  });

  group("public facade owned upload", () {
    test("queued captures drain through the owned upload path when ready",
        () async {
      final _ScriptedBootstrapProbe bootstrapProbe = _ScriptedBootstrapProbe(
        <bootstrap_internal.RevclustBootstrapAssessment>[
          _readyAssessment(),
        ],
      );
      final _FakeUploadTransport uploadTransport = _FakeUploadTransport(
        (low_level.LocalPackRecord claimedPack,
            bootstrap_internal.RevclustBootstrapLease _) async {
          return upload_internal.RevclustOwnedUploadAccepted(
            facade.RevclustAcceptedResult(
              packId: "ppk_accept_001",
              schemaVersion: "1.0.0",
              blobBytesGzip: claimedPack.gzipBytes.lengthInBytes,
              acceptedAt: DateTime.parse("2026-03-28T12:00:00Z"),
              viewerUrl: Uri.parse(
                  "https://revclust.com/app/incidents/ppk_accept_001"),
            ),
          );
        },
      );
      _installUploadHarness(
        bootstrapProbe: bootstrapProbe,
        uploadTransport: uploadTransport,
      );

      final facade.Revclust revclust = await facade.Revclust.initialize(
        _config(),
      );
      final List<facade.RevclustUploadEvent> events =
          <facade.RevclustUploadEvent>[];
      final List<facade.RevclustUploadSnapshot> snapshotsAtEvents =
          <facade.RevclustUploadSnapshot>[];
      revclust.uploadEvents.listen((facade.RevclustUploadEvent event) {
        events.add(event);
        snapshotsAtEvents.add(revclust.uploadSnapshot);
      });

      final facade.RevclustCaptureQueued queued = (await revclust
          .captureInvariantFailure(_failure())) as facade.RevclustCaptureQueued;

      await _waitFor(() async {
        return events.length == 2 &&
            await localCaptureFactory.countPending() == 0 &&
            await localCaptureFactory.countUploading() == 0;
      });

      expect(uploadTransport.callCount, 1);
      expect(events[0], isA<facade.RevclustUploadStarted>());
      expect(events[1], isA<facade.RevclustUploadAccepted>());
      expect(events[0].captureId, queued.captureId);
      expect(events[1].captureId, queued.captureId);
      expect(
        (events[1] as facade.RevclustUploadAccepted).result.packId,
        "ppk_accept_001",
      );
      expect(snapshotsAtEvents[0].pendingCount, 0);
      expect(snapshotsAtEvents[0].uploadingCount, 1);
      expect(snapshotsAtEvents[0].lastErrorCode, isNull);
      expect(snapshotsAtEvents[1].pendingCount, 0);
      expect(snapshotsAtEvents[1].uploadingCount, 0);
      expect(snapshotsAtEvents[1].lastErrorCode, isNull);
      expect(revclust.uploadSnapshot.pendingCount, 0);
      expect(revclust.uploadSnapshot.uploadingCount, 0);
      expect(revclust.uploadSnapshot.lastErrorCode, isNull);
    });

    test("bootstrapUnavailable still permits local queueing but does not drain",
        () async {
      final _ScriptedBootstrapProbe bootstrapProbe = _ScriptedBootstrapProbe(
        const <bootstrap_internal.RevclustBootstrapAssessment>[
          bootstrap_internal.RevclustBootstrapAssessment.bootstrapUnavailable(
            message: "Bootstrap is unavailable.",
          ),
        ],
      );
      final _FakeUploadTransport uploadTransport = _FakeUploadTransport(
        (_, __) async {
          throw StateError("upload transport should not be called");
        },
      );
      _installUploadHarness(
        bootstrapProbe: bootstrapProbe,
        uploadTransport: uploadTransport,
      );

      final facade.Revclust revclust = await facade.Revclust.initialize(
        _config(),
      );
      final List<facade.RevclustUploadEvent> events =
          <facade.RevclustUploadEvent>[];
      revclust.uploadEvents.listen(events.add);

      final facade.RevclustCaptureOutcome outcome =
          await revclust.captureInvariantFailure(
        _failure(),
      );
      await _drainEventQueue();

      expect(outcome, isA<facade.RevclustCaptureQueued>());
      expect(revclust.status, facade.RevclustStatus.degraded);
      expect(await localCaptureFactory.countPending(), 1);
      expect(await localCaptureFactory.countUploading(), 0);
      expect(uploadTransport.callCount, 0);
      expect(events, isEmpty);
      expect(
        revclust.uploadSnapshot.lastErrorCode,
        facade.RevclustUploadErrorCode.transportUnavailable,
      );
    });

    test(
        "misconfigured and notProvisioned states stay visible and do not drain",
        () async {
      facade_internal.RevclustFacadeTestSupport.reset();
      await localCaptureFactory.dispose();
      localCaptureFactory = TestPublicFacadeLocalCaptureFactory(
        utcNowMs: () => clockMs,
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
      facade_internal.RevclustFacadeTestSupport.utcNow = _utcNowFactory(
        () => clockMs,
      );

      final _FakeUploadTransport uploadTransport = _FakeUploadTransport(
        (_, __) async {
          throw StateError("upload transport should not be called");
        },
      );

      facade_internal.RevclustFacadeTestSupport.bootstrapProbe =
          _ScriptedBootstrapProbe(
        const <bootstrap_internal.RevclustBootstrapAssessment>[
          bootstrap_internal.RevclustBootstrapAssessment.misconfigured(
            message: "Project key is misconfigured.",
          ),
        ],
      );
      facade_internal.RevclustFacadeTestSupport.uploadTransport =
          uploadTransport;
      final facade.Revclust misconfiguredFacade =
          await facade.Revclust.initialize(
        _config(projectKey: _misconfiguredProjectKey),
      );

      expect(misconfiguredFacade.status, facade.RevclustStatus.misconfigured);
      expect(misconfiguredFacade.uploadSnapshot.pendingCount, 1);
      expect(misconfiguredFacade.uploadSnapshot.uploadingCount, 0);
      expect(uploadTransport.callCount, 0);

      facade_internal.RevclustFacadeTestSupport.reset();
      facade_internal.RevclustFacadeTestSupport.localCaptureFactory =
          localCaptureFactory;
      facade_internal.RevclustFacadeTestSupport.utcNow = _utcNowFactory(
        () => clockMs,
      );
      facade_internal.RevclustFacadeTestSupport.bootstrapProbe =
          _ScriptedBootstrapProbe(
        const <bootstrap_internal.RevclustBootstrapAssessment>[
          bootstrap_internal.RevclustBootstrapAssessment.notProvisioned(
            message: "Project key is not provisioned.",
          ),
        ],
      );
      facade_internal.RevclustFacadeTestSupport.uploadTransport =
          uploadTransport;
      final facade.Revclust notProvisionedFacade =
          await facade.Revclust.initialize(
        _config(projectKey: _missingProjectKey),
      );

      expect(
        notProvisionedFacade.status,
        facade.RevclustStatus.notProvisioned,
      );
      expect(notProvisionedFacade.uploadSnapshot.pendingCount, 1);
      expect(notProvisionedFacade.uploadSnapshot.uploadingCount, 0);
      expect(uploadTransport.callCount, 0);
    });

    test("rejected uploads emit Started then Rejected and move terminal failed",
        () async {
      final _FakeUploadTransport uploadTransport = _FakeUploadTransport(
        (_, __) async => const upload_internal.RevclustOwnedUploadRejected(
          code: facade.RevclustRejectionCode.invalidRequest,
          errorCode: facade.RevclustUploadErrorCode.invalidRequest,
          message: "metadata mismatch",
          statusCode: 400,
        ),
      );
      _installUploadHarness(
        bootstrapProbe: _ScriptedBootstrapProbe(
          <bootstrap_internal.RevclustBootstrapAssessment>[
            _readyAssessment(),
          ],
        ),
        uploadTransport: uploadTransport,
      );

      final facade.Revclust revclust = await facade.Revclust.initialize(
        _config(),
      );
      final List<facade.RevclustUploadEvent> events =
          <facade.RevclustUploadEvent>[];
      revclust.uploadEvents.listen(events.add);

      final facade.RevclustCaptureQueued queued = (await revclust
          .captureInvariantFailure(_failure())) as facade.RevclustCaptureQueued;
      await _waitFor(() async => events.length == 2);

      final low_level.LocalPackRecord? record =
          await localCaptureFactory.getById(queued.captureId);
      expect(events[0], isA<facade.RevclustUploadStarted>());
      expect(events[1], isA<facade.RevclustUploadRejected>());
      expect(events[1].captureId, queued.captureId);
      expect(
        (events[1] as facade.RevclustUploadRejected).code,
        facade.RevclustRejectionCode.invalidRequest,
      );
      expect(record?.status, low_level.LocalPackRepository.statusFailed);
      expect(revclust.uploadSnapshot.pendingCount, 0);
      expect(revclust.uploadSnapshot.uploadingCount, 0);
      expect(
        revclust.uploadSnapshot.lastErrorCode,
        facade.RevclustUploadErrorCode.invalidRequest,
      );
    });

    test(
        "transport failure retries with bounded policy and keeps ordering real",
        () async {
      int attempt = 0;
      final _FakeUploadTransport uploadTransport = _FakeUploadTransport(
        (low_level.LocalPackRecord claimedPack,
            bootstrap_internal.RevclustBootstrapLease _) async {
          attempt += 1;
          if (attempt == 1) {
            return const upload_internal.RevclustOwnedUploadTransportFailure(
              errorCode: facade.RevclustUploadErrorCode.transportUnavailable,
              retryable: true,
              message: "temporary upstream failure",
              statusCode: 503,
            );
          }
          return upload_internal.RevclustOwnedUploadAccepted(
            facade.RevclustAcceptedResult(
              packId: "ppk_retry_ok",
              schemaVersion: "1.0.0",
              blobBytesGzip: claimedPack.gzipBytes.lengthInBytes,
              acceptedAt: DateTime.parse("2026-03-28T12:30:00Z"),
            ),
          );
        },
      );
      _installUploadHarness(
        bootstrapProbe: _ScriptedBootstrapProbe(
          <bootstrap_internal.RevclustBootstrapAssessment>[
            _readyAssessment(),
          ],
        ),
        uploadTransport: uploadTransport,
        retryPolicy: const upload_internal.RevclustOwnedUploadRetryPolicy(
          backoffSchedule: <Duration>[Duration.zero],
        ),
      );

      final facade.Revclust revclust = await facade.Revclust.initialize(
        _config(),
      );
      final List<facade.RevclustUploadEvent> events =
          <facade.RevclustUploadEvent>[];
      final List<facade.RevclustUploadSnapshot> snapshots =
          <facade.RevclustUploadSnapshot>[];
      revclust.uploadEvents.listen((facade.RevclustUploadEvent event) {
        events.add(event);
        snapshots.add(revclust.uploadSnapshot);
      });

      await revclust.captureInvariantFailure(_failure());
      await _waitFor(() async => events.length == 4);

      expect(events[0], isA<facade.RevclustUploadStarted>());
      expect(events[1], isA<facade.RevclustTransportFailure>());
      expect(events[2], isA<facade.RevclustUploadStarted>());
      expect(events[3], isA<facade.RevclustUploadAccepted>());
      expect((events[1] as facade.RevclustTransportFailure).retryable, isTrue);
      expect(snapshots[1].pendingCount, 1);
      expect(snapshots[1].uploadingCount, 0);
      expect(
        snapshots[1].lastErrorCode,
        facade.RevclustUploadErrorCode.transportUnavailable,
      );
      expect(snapshots[2].pendingCount, 0);
      expect(snapshots[2].uploadingCount, 1);
      expect(revclust.uploadSnapshot.pendingCount, 0);
      expect(revclust.uploadSnapshot.uploadingCount, 0);
      expect(revclust.uploadSnapshot.lastErrorCode, isNull);
    });

    test("retry exhaustion moves the item to terminal failed", () async {
      final _FakeUploadTransport uploadTransport = _FakeUploadTransport(
        (_, __) async =>
            const upload_internal.RevclustOwnedUploadTransportFailure(
          errorCode: facade.RevclustUploadErrorCode.transportUnavailable,
          retryable: true,
          message: "still unavailable",
          statusCode: 503,
        ),
      );
      _installUploadHarness(
        bootstrapProbe: _ScriptedBootstrapProbe(
          <bootstrap_internal.RevclustBootstrapAssessment>[
            _readyAssessment(),
          ],
        ),
        uploadTransport: uploadTransport,
        retryPolicy: const upload_internal.RevclustOwnedUploadRetryPolicy(
          maxAttempts: 2,
          backoffSchedule: <Duration>[Duration.zero],
        ),
      );

      final facade.Revclust revclust = await facade.Revclust.initialize(
        _config(),
      );
      final List<facade.RevclustUploadEvent> events =
          <facade.RevclustUploadEvent>[];
      revclust.uploadEvents.listen(events.add);

      final facade.RevclustCaptureQueued queued = (await revclust
          .captureInvariantFailure(_failure())) as facade.RevclustCaptureQueued;
      await _waitFor(() async => events.length == 4);

      final low_level.LocalPackRecord? record =
          await localCaptureFactory.getById(queued.captureId);
      expect(events[0], isA<facade.RevclustUploadStarted>());
      expect(events[1], isA<facade.RevclustTransportFailure>());
      expect(events[2], isA<facade.RevclustUploadStarted>());
      expect(events[3], isA<facade.RevclustTransportFailure>());
      expect((events[3] as facade.RevclustTransportFailure).retryable, isFalse);
      expect(record?.status, low_level.LocalPackRepository.statusFailed);
      expect(revclust.uploadSnapshot.pendingCount, 0);
      expect(revclust.uploadSnapshot.uploadingCount, 0);
    });

    test("auth expiry during drain becomes visible and leaves work queued",
        () async {
      final _ScriptedBootstrapProbe bootstrapProbe = _ScriptedBootstrapProbe(
        <bootstrap_internal.RevclustBootstrapAssessment>[
          _readyAssessment(token: "stale_auth"),
          const bootstrap_internal.RevclustBootstrapAssessment.uploadBlocked(
            message: "Upload auth could not be refreshed.",
          ),
        ],
      );
      final _FakeUploadTransport uploadTransport = _FakeUploadTransport(
        (_, __) async => const upload_internal.RevclustOwnedUploadRejected(
          code: facade.RevclustRejectionCode.auth,
          errorCode: facade.RevclustUploadErrorCode.auth,
          message: "upload auth expired",
          statusCode: 403,
        ),
      );
      _installUploadHarness(
        bootstrapProbe: bootstrapProbe,
        uploadTransport: uploadTransport,
      );

      final facade.Revclust revclust = await facade.Revclust.initialize(
        _config(),
      );
      final List<facade.RevclustUploadEvent> events =
          <facade.RevclustUploadEvent>[];
      revclust.uploadEvents.listen(events.add);

      await revclust.captureInvariantFailure(_failure());
      await _waitFor(() async => events.length == 2);

      expect(revclust.status, facade.RevclustStatus.uploadBlocked);
      expect(events[0], isA<facade.RevclustUploadStarted>());
      expect(events[1], isA<facade.RevclustTransportFailure>());
      expect((events[1] as facade.RevclustTransportFailure).retryable, isTrue);
      expect(await localCaptureFactory.countPending(), 1);
      expect(await localCaptureFactory.countUploading(), 0);
      expect(revclust.uploadSnapshot.pendingCount, 1);
      expect(revclust.uploadSnapshot.uploadingCount, 0);
      expect(
        revclust.uploadSnapshot.lastErrorCode,
        facade.RevclustUploadErrorCode.auth,
      );
    });

    test("restart and resume do not double-drain claimed work", () async {
      final Completer<upload_internal.RevclustOwnedUploadTransportResult>
          firstAttemptCompleter =
          Completer<upload_internal.RevclustOwnedUploadTransportResult>();
      final _FakeUploadTransport firstTransport = _FakeUploadTransport(
        (_, __) => firstAttemptCompleter.future,
      );
      _installUploadHarness(
        bootstrapProbe: _ScriptedBootstrapProbe(
          <bootstrap_internal.RevclustBootstrapAssessment>[
            _readyAssessment(),
          ],
        ),
        uploadTransport: firstTransport,
        retryPolicy: const upload_internal.RevclustOwnedUploadRetryPolicy(
          claimLease: Duration(milliseconds: 1000),
        ),
      );

      final facade.Revclust firstFacade = await facade.Revclust.initialize(
        _config(),
      );
      final List<facade.RevclustUploadEvent> firstEvents =
          <facade.RevclustUploadEvent>[];
      firstFacade.uploadEvents.listen(firstEvents.add);

      await firstFacade.captureInvariantFailure(_failure());
      await _waitFor(() async => firstEvents.length == 1);
      expect(firstEvents.single, isA<facade.RevclustUploadStarted>());
      expect(await localCaptureFactory.countPending(), 0);
      expect(await localCaptureFactory.countUploading(), 1);

      facade_internal.RevclustFacadeTestSupport.reset();
      facade_internal.RevclustFacadeTestSupport.localCaptureFactory =
          localCaptureFactory;
      facade_internal.RevclustFacadeTestSupport.utcNow = _utcNowFactory(
        () => clockMs,
      );
      final _FakeUploadTransport resumedTransport = _FakeUploadTransport(
        (low_level.LocalPackRecord claimedPack,
            bootstrap_internal.RevclustBootstrapLease _) async {
          return upload_internal.RevclustOwnedUploadAccepted(
            facade.RevclustAcceptedResult(
              packId: "ppk_resume_001",
              schemaVersion: "1.0.0",
              blobBytesGzip: claimedPack.gzipBytes.lengthInBytes,
              acceptedAt: DateTime.parse("2026-03-28T13:00:00Z"),
            ),
          );
        },
      );
      _installUploadHarness(
        bootstrapProbe: _ScriptedBootstrapProbe(
          <bootstrap_internal.RevclustBootstrapAssessment>[
            _readyAssessment(),
          ],
        ),
        uploadTransport: resumedTransport,
        retryPolicy: const upload_internal.RevclustOwnedUploadRetryPolicy(
          claimLease: Duration(milliseconds: 1000),
        ),
      );

      final facade.Revclust secondFacade = await facade.Revclust.initialize(
        _config(),
      );
      await _drainEventQueue();
      expect(secondFacade.uploadSnapshot.pendingCount, 0);
      expect(secondFacade.uploadSnapshot.uploadingCount, 1);
      expect(resumedTransport.callCount, 0);

      facade_internal.RevclustFacadeTestSupport.reset();
      clockMs = 2501;
      facade_internal.RevclustFacadeTestSupport.localCaptureFactory =
          localCaptureFactory;
      facade_internal.RevclustFacadeTestSupport.utcNow = _utcNowFactory(
        () => clockMs,
      );
      _installUploadHarness(
        bootstrapProbe: _ScriptedBootstrapProbe(
          <bootstrap_internal.RevclustBootstrapAssessment>[
            _readyAssessment(),
          ],
        ),
        uploadTransport: resumedTransport,
        retryPolicy: const upload_internal.RevclustOwnedUploadRetryPolicy(
          claimLease: Duration(milliseconds: 1000),
        ),
      );

      final facade.Revclust thirdFacade = await facade.Revclust.initialize(
        _config(),
      );
      await _waitFor(() async => resumedTransport.callCount == 1);
      await _waitFor(() async => await localCaptureFactory.countPending() == 0);

      expect(resumedTransport.callCount, 1);
      expect(thirdFacade.uploadSnapshot.pendingCount, 0);
      expect(thirdFacade.uploadSnapshot.uploadingCount, 0);
    });

    test(
        "queued work arriving during drain wind-down reruns without another trigger",
        () async {
      int clockMs = 1000;
      final _RepositoryHarness<_BlockingNextPendingRepository>
          repositoryHarness = await _openBlockingNextPendingRepository(
        utcNowMs: () => clockMs,
      );
      addTearDown(repositoryHarness.dispose);
      final _BlockingNextPendingRepository repository =
          repositoryHarness.repository;
      await repository.savePending(
        buildSeededPackResult(captureId: "cap_first_001"),
      );
      final _FakeUploadTransport uploadTransport = _FakeUploadTransport(
        (low_level.LocalPackRecord claimedPack,
            bootstrap_internal.RevclustBootstrapLease _) async {
          return upload_internal.RevclustOwnedUploadAccepted(
            facade.RevclustAcceptedResult(
              packId: "pack_${claimedPack.captureId}",
              schemaVersion: "1.0.0",
              blobBytesGzip: claimedPack.gzipBytes.lengthInBytes,
              acceptedAt: DateTime.parse("2026-03-28T14:00:00Z"),
            ),
          );
        },
      );
      final List<facade.RevclustUploadEvent> events =
          <facade.RevclustUploadEvent>[];
      final upload_internal.RevclustOwnedUploadCoordinator coordinator =
          upload_internal.RevclustOwnedUploadCoordinator(
        repository: repository,
        bootstrapDelegate: _FixedDrainBootstrapDelegate.ready(),
        transport: uploadTransport,
        retryPolicy: const upload_internal.RevclustOwnedUploadRetryPolicy(
          backoffSchedule: <Duration>[Duration.zero],
        ),
        utcNow: _utcNowFactory(() => clockMs),
        onQueueStateChanged: () async {},
        onLastError: (_) {},
        onEvent: events.add,
      );
      addTearDown(coordinator.dispose);

      coordinator.requestDrain();
      await repository.nextPendingAttemptEntered.future;
      await repository.savePending(
        buildSeededPackResult(captureId: "cap_second_001"),
      );
      coordinator.requestDrain();
      repository.allowNextPendingAttemptReturn.complete();

      await _waitFor(() async {
        final low_level.LocalPackQueueState queueState =
            await repository.describeQueue();
        return uploadTransport.callCount == 2 &&
            queueState.pendingCount == 0 &&
            queueState.uploadingCount == 0;
      });

      expect(uploadTransport.captureIds, <String>[
        "cap_first_001",
        "cap_second_001",
      ]);
      expect(events[0], isA<facade.RevclustUploadStarted>());
      expect(events[1], isA<facade.RevclustUploadAccepted>());
      expect(events[2], isA<facade.RevclustUploadStarted>());
      expect(events[3], isA<facade.RevclustUploadAccepted>());
    });

    test("uploading-only stale claims self-recover after lease expiry",
        () async {
      final _RepositoryHarness<low_level.LocalPackRepository>
          repositoryHarness = await _openRepository(
        utcNowMs: () => DateTime.now().toUtc().millisecondsSinceEpoch,
      );
      addTearDown(repositoryHarness.dispose);
      final low_level.LocalPackRepository repository =
          repositoryHarness.repository;
      await repository.savePending(
        buildSeededPackResult(captureId: "cap_stale_001"),
      );
      await repository.claimNextUploadable();

      final _FakeUploadTransport uploadTransport = _FakeUploadTransport(
        (low_level.LocalPackRecord claimedPack,
            bootstrap_internal.RevclustBootstrapLease _) async {
          return upload_internal.RevclustOwnedUploadAccepted(
            facade.RevclustAcceptedResult(
              packId: "pack_${claimedPack.captureId}",
              schemaVersion: "1.0.0",
              blobBytesGzip: claimedPack.gzipBytes.lengthInBytes,
              acceptedAt: DateTime.parse("2026-03-28T14:10:00Z"),
            ),
          );
        },
      );
      final upload_internal.RevclustOwnedUploadCoordinator coordinator =
          upload_internal.RevclustOwnedUploadCoordinator(
        repository: repository,
        bootstrapDelegate: _FixedDrainBootstrapDelegate.ready(),
        transport: uploadTransport,
        retryPolicy: const upload_internal.RevclustOwnedUploadRetryPolicy(
          claimLease: Duration(milliseconds: 100),
          backoffSchedule: <Duration>[Duration.zero],
        ),
        utcNow: () => DateTime.now().toUtc(),
        onQueueStateChanged: () async {},
        onLastError: (_) {},
        onEvent: (_) {},
      );
      addTearDown(coordinator.dispose);

      coordinator.requestDrain();

      await _waitFor(() async {
        final low_level.LocalPackQueueState queueState =
            await repository.describeQueue();
        return uploadTransport.callCount == 1 &&
            queueState.pendingCount == 0 &&
            queueState.uploadingCount == 0;
      }, stepDelay: const Duration(milliseconds: 10));

      expect(uploadTransport.captureIds, <String>["cap_stale_001"]);
    });

    test(
        "unexpected transport exceptions stay contained and recover visible facade state",
        () async {
      facade_internal.RevclustFacadeTestSupport.reset();
      await localCaptureFactory.dispose();
      localCaptureFactory = TestPublicFacadeLocalCaptureFactory(
        utcNowMs: () => DateTime.now().toUtc().millisecondsSinceEpoch,
      );
      facade_internal.RevclustFacadeTestSupport.localCaptureFactory =
          localCaptureFactory;
      facade_internal.RevclustFacadeTestSupport.utcNow =
          () => DateTime.now().toUtc();

      int rawAttempt = 0;
      final _FakeUploadTransport uploadTransport = _FakeUploadTransport(
        (low_level.LocalPackRecord claimedPack,
            bootstrap_internal.RevclustBootstrapLease _) async {
          rawAttempt += 1;
          if (rawAttempt == 1) {
            throw StateError("simulated raw transport failure");
          }
          return upload_internal.RevclustOwnedUploadAccepted(
            facade.RevclustAcceptedResult(
              packId: "ppk_recovered_001",
              schemaVersion: "1.0.0",
              blobBytesGzip: claimedPack.gzipBytes.lengthInBytes,
              acceptedAt: DateTime.parse("2026-03-28T14:20:00Z"),
            ),
          );
        },
      );
      _installUploadHarness(
        bootstrapProbe: _ScriptedBootstrapProbe(
          <bootstrap_internal.RevclustBootstrapAssessment>[
            _readyAssessment(),
          ],
        ),
        uploadTransport: uploadTransport,
        retryPolicy: const upload_internal.RevclustOwnedUploadRetryPolicy(
          claimLease: Duration(milliseconds: 100),
          backoffSchedule: <Duration>[Duration.zero],
        ),
      );

      final facade.Revclust revclust = await facade.Revclust.initialize(
        _config(),
      );
      final List<facade.RevclustUploadEvent> events =
          <facade.RevclustUploadEvent>[];
      revclust.uploadEvents.listen(events.add);

      await revclust.captureInvariantFailure(_failure());
      await _waitFor(() async {
        return uploadTransport.callCount == 1 &&
            revclust.uploadSnapshot.uploadingCount == 1 &&
            revclust.uploadSnapshot.lastErrorCode ==
                facade.RevclustUploadErrorCode.internalError;
      });
      await _waitFor(() async {
        return uploadTransport.callCount == 2 &&
            revclust.uploadSnapshot.pendingCount == 0 &&
            revclust.uploadSnapshot.uploadingCount == 0 &&
            revclust.uploadSnapshot.lastErrorCode == null;
      }, stepDelay: const Duration(milliseconds: 10));

      expect(revclust.uploadSnapshot.pendingCount, 0);
      expect(revclust.uploadSnapshot.uploadingCount, 0);
      expect(revclust.uploadSnapshot.lastErrorCode, isNull);
      expect(events[0], isA<facade.RevclustUploadStarted>());
      expect(events[1], isA<facade.RevclustUploadStarted>());
      expect(events[2], isA<facade.RevclustUploadAccepted>());
    });

    test("stale-claim recovery does not spend retry budget before upload",
        () async {
      int clockMs = 1000;
      final _RepositoryHarness<low_level.LocalPackRepository>
          repositoryHarness = await _openRepository(
        utcNowMs: () => clockMs,
      );
      addTearDown(repositoryHarness.dispose);
      final low_level.LocalPackRepository repository =
          repositoryHarness.repository;
      await repository.savePending(
        buildSeededPackResult(captureId: "cap_retry_budget_001"),
      );
      await repository.claimNextUploadable();
      clockMs = 2500;

      int attempt = 0;
      final _FakeUploadTransport uploadTransport = _FakeUploadTransport(
        (low_level.LocalPackRecord claimedPack,
            bootstrap_internal.RevclustBootstrapLease _) async {
          attempt += 1;
          if (attempt == 1) {
            return const upload_internal.RevclustOwnedUploadTransportFailure(
              errorCode: facade.RevclustUploadErrorCode.transportUnavailable,
              retryable: true,
              message: "temporary outage",
              statusCode: 503,
            );
          }
          return upload_internal.RevclustOwnedUploadAccepted(
            facade.RevclustAcceptedResult(
              packId: "ppk_retry_budget_001",
              schemaVersion: "1.0.0",
              blobBytesGzip: claimedPack.gzipBytes.lengthInBytes,
              acceptedAt: DateTime.parse("2026-03-28T14:30:00Z"),
            ),
          );
        },
      );
      final List<facade.RevclustUploadEvent> events =
          <facade.RevclustUploadEvent>[];
      final upload_internal.RevclustOwnedUploadCoordinator coordinator =
          upload_internal.RevclustOwnedUploadCoordinator(
        repository: repository,
        bootstrapDelegate: _FixedDrainBootstrapDelegate.ready(),
        transport: uploadTransport,
        retryPolicy: const upload_internal.RevclustOwnedUploadRetryPolicy(
          maxAttempts: 2,
          claimLease: Duration(milliseconds: 1000),
          backoffSchedule: <Duration>[Duration.zero],
        ),
        utcNow: _utcNowFactory(() => clockMs),
        onQueueStateChanged: () async {},
        onLastError: (_) {},
        onEvent: events.add,
      );
      addTearDown(coordinator.dispose);

      coordinator.requestDrain();
      await _waitFor(() async {
        final low_level.LocalPackRecord? record =
            await repository.getById("cap_retry_budget_001");
        return uploadTransport.callCount == 2 &&
            record?.status == low_level.LocalPackRepository.statusUploaded;
      });

      final low_level.LocalPackRecord? record =
          await repository.getById("cap_retry_budget_001");
      expect(events[0], isA<facade.RevclustUploadStarted>());
      expect(events[1], isA<facade.RevclustTransportFailure>());
      expect((events[1] as facade.RevclustTransportFailure).retryable, isTrue);
      expect(events[2], isA<facade.RevclustUploadStarted>());
      expect(events[3], isA<facade.RevclustUploadAccepted>());
      expect(record, isNotNull);
      expect(record!.attemptCount, 2);
    });
  });
}

facade.RevclustConfig _config({
  String projectKey = _defaultProjectKey,
}) {
  return facade.RevclustConfig(
    projectKey: projectKey,
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

void _installUploadHarness({
  required bootstrap_internal.RevclustBootstrapProbe bootstrapProbe,
  required upload_internal.RevclustOwnedUploadTransport uploadTransport,
  upload_internal.RevclustOwnedUploadRetryPolicy retryPolicy =
      const upload_internal.RevclustOwnedUploadRetryPolicy(),
}) {
  facade_internal.RevclustFacadeTestSupport.bootstrapProbe = bootstrapProbe;
  facade_internal.RevclustFacadeTestSupport.uploadTransport = uploadTransport;
  facade_internal.RevclustFacadeTestSupport.uploadRetryPolicy = retryPolicy;
}

bootstrap_internal.RevclustBootstrapAssessment _readyAssessment({
  String token = "incident_upload_auth_live",
}) {
  return bootstrap_internal.RevclustBootstrapAssessment.ready(
    lease: bootstrap_internal.RevclustBootstrapLease(
      uploadEndpoint: Uri.parse("https://revclust.com/api/incident-packs"),
      authToken: token,
      usableUntil: DateTime.parse("2030-01-01T00:00:00Z"),
      viewerBaseUrl: Uri.parse("https://revclust.com/app/incidents"),
    ),
  );
}

DateTime Function() _utcNowFactory(int Function() clockMs) {
  return () => DateTime.fromMillisecondsSinceEpoch(
        clockMs(),
        isUtc: true,
      );
}

Future<void> _waitFor(
  FutureOr<bool> Function() condition, {
  int maxAttempts = 100,
  Duration stepDelay = Duration.zero,
}) async {
  for (int attempt = 0; attempt < maxAttempts; attempt += 1) {
    if (await condition()) {
      return;
    }
    await _drainEventQueue();
    if (stepDelay > Duration.zero) {
      await Future<void>.delayed(stepDelay);
    }
  }
  throw StateError("Timed out waiting for upload test condition.");
}

Future<void> _drainEventQueue() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

final class _ScriptedBootstrapProbe
    implements bootstrap_internal.RevclustBootstrapProbe {
  _ScriptedBootstrapProbe(this._assessments);

  final List<bootstrap_internal.RevclustBootstrapAssessment> _assessments;
  int assessCallCount = 0;

  @override
  Future<bootstrap_internal.RevclustBootstrapAssessment> assess(
    facade.RevclustConfig config,
  ) async {
    if (_assessments.isEmpty) {
      throw StateError("No bootstrap assessments configured.");
    }
    final int index = assessCallCount >= _assessments.length
        ? _assessments.length - 1
        : assessCallCount;
    assessCallCount += 1;
    return _assessments[index];
  }
}

final class _FakeUploadTransport
    implements upload_internal.RevclustOwnedUploadTransport {
  _FakeUploadTransport(this._upload);

  final Future<upload_internal.RevclustOwnedUploadTransportResult> Function(
    low_level.LocalPackRecord claimedPack,
    bootstrap_internal.RevclustBootstrapLease lease,
  ) _upload;

  int callCount = 0;
  final List<String> captureIds = <String>[];
  final List<String> authTokens = <String>[];

  @override
  Future<upload_internal.RevclustOwnedUploadTransportResult> upload({
    required low_level.LocalPackRecord claimedPack,
    required bootstrap_internal.RevclustBootstrapLease lease,
  }) {
    callCount += 1;
    captureIds.add(claimedPack.captureId);
    authTokens.add(lease.authToken);
    return _upload(claimedPack, lease);
  }
}

final class _FixedDrainBootstrapDelegate
    implements upload_internal.RevclustDrainBootstrapDelegate {
  _FixedDrainBootstrapDelegate(this._access);

  factory _FixedDrainBootstrapDelegate.ready() {
    return _FixedDrainBootstrapDelegate(
      upload_internal.RevclustDrainAccessReady(
        _readyAssessment().lease!,
      ),
    );
  }

  final upload_internal.RevclustDrainAccess _access;

  @override
  Future<upload_internal.RevclustDrainAccess> ensureReadyForDrain() async {
    return _access;
  }

  @override
  Future<upload_internal.RevclustDrainAccess> refreshAfterAuthFailure() async {
    return _access;
  }
}

final class _RepositoryHarness<T extends low_level.LocalPackRepository> {
  _RepositoryHarness({
    required this.repository,
    required Directory tempDirectory,
  }) : _tempDirectory = tempDirectory;

  final T repository;
  final Directory _tempDirectory;

  Future<void> dispose() async {
    await repository.close();
    if (await _tempDirectory.exists()) {
      await _tempDirectory.delete(recursive: true);
    }
  }
}

Future<_RepositoryHarness<low_level.LocalPackRepository>> _openRepository({
  required int Function() utcNowMs,
}) async {
  final Directory tempDirectory = await Directory.systemTemp.createTemp(
    "revclust_public_facade_upload_repo_",
  );
  final low_level.LocalPackRepository repository =
      low_level.LocalPackRepository(
    encryptionService: low_level.AesGcmEncryptionService(
      keyStore: InMemoryKeyStore(),
    ),
    databasePath: "${tempDirectory.path}/packs.db",
    databaseFactory: databaseFactoryFfiNoIsolate,
    utcNowMs: utcNowMs,
  );
  return _RepositoryHarness<low_level.LocalPackRepository>(
    repository: repository,
    tempDirectory: tempDirectory,
  );
}

Future<_RepositoryHarness<_BlockingNextPendingRepository>>
    _openBlockingNextPendingRepository({
  required int Function() utcNowMs,
}) async {
  final Directory tempDirectory = await Directory.systemTemp.createTemp(
    "revclust_public_facade_upload_blocking_repo_",
  );
  final _BlockingNextPendingRepository repository =
      _BlockingNextPendingRepository(
    encryptionService: low_level.AesGcmEncryptionService(
      keyStore: InMemoryKeyStore(),
    ),
    databasePath: "${tempDirectory.path}/packs.db",
    databaseFactory: databaseFactoryFfiNoIsolate,
    utcNowMs: utcNowMs,
  );
  return _RepositoryHarness<_BlockingNextPendingRepository>(
    repository: repository,
    tempDirectory: tempDirectory,
  );
}

final class _BlockingNextPendingRepository
    extends low_level.LocalPackRepository {
  _BlockingNextPendingRepository({
    required super.encryptionService,
    required super.databasePath,
    required super.databaseFactory,
    required super.utcNowMs,
  });

  final Completer<void> nextPendingAttemptEntered = Completer<void>();
  final Completer<void> allowNextPendingAttemptReturn = Completer<void>();
  bool _shouldBlockNextPendingAttempt = true;

  @override
  Future<int?> nextPendingAttemptAt() async {
    final int? result = await super.nextPendingAttemptAt();
    if (!_shouldBlockNextPendingAttempt) {
      return result;
    }
    _shouldBlockNextPendingAttempt = false;
    if (!nextPendingAttemptEntered.isCompleted) {
      nextPendingAttemptEntered.complete();
    }
    await allowNextPendingAttemptReturn.future;
    return result;
  }
}
