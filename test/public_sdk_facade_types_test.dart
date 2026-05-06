import "dart:io";
import "dart:typed_data";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter_sdk/revclust_flutter.dart" as facade;
import "package:revclust_flutter_sdk/revclust_flutter_sdk.dart" as low_level;
import "package:revclust_flutter_sdk/src/persistence/revclust_database_factory.dart";
import "package:revclust_flutter_sdk/src/public/revclust.dart"
    as facade_internal;
import "package:revclust_flutter_sdk/src/public/revclust_owned_upload.dart"
    as upload_internal;

import "support/in_memory_key_store.dart";
import "support/public_facade_local_capture_factory.dart";

const String _projectKey = "rpk_uC4n8XQvJ9tR2mLsY7pKdB3fW6zHaNe1";

void main() {
  late TestPublicFacadeLocalCaptureFactory localCaptureFactory;

  setUp(() {
    facade_internal.RevclustFacadeTestSupport.reset();
    localCaptureFactory = TestPublicFacadeLocalCaptureFactory();
    facade_internal.RevclustFacadeTestSupport.localCaptureFactory =
        localCaptureFactory;
  });

  tearDown(() async {
    facade_internal.RevclustFacadeTestSupport.reset();
    await localCaptureFactory.dispose();
  });

  test("partner-facing entrypoint exposes the new facade types", () {
    final facade.RevclustConfig config = facade.RevclustConfig(
      projectKey: _projectKey,
      environment: facade.RevclustEnvironment.staging,
    );
    final facade.RevclustIdentity identity = facade.RevclustIdentity(
      kind: "order",
      value: "ord_123",
    );
    final facade.RevclustTrigger trigger = facade.RevclustTrigger(
      reason: "checkout confirmation mismatch",
      expected: const <String, Object?>{"order_status": "confirmed"},
      observed: const <String, Object?>{"order_status": "retrying"},
      identity: identity,
      signature: "checkout_confirmation_mismatch",
      flow: "checkout",
      screen: "confirmation",
      stepLabel: "confirm_order",
      reproHint: "Retry checkout after a slow confirmation poll.",
      relevantIds: const <String, String>{
        "cart_id": "cart_123",
      },
    );
    final facade.RevclustCaptureQueued queued =
        facade.RevclustCaptureQueued(captureId: "cap_123");
    final facade.RevclustCaptureOutcome blocked = facade.RevclustCaptureBlocked(
      status: facade.RevclustStatus.misconfigured,
      message: "Project key is not provisioned for this environment.",
    );
    final facade.RevclustCaptureBuildFailed buildFailed =
        facade.RevclustCaptureBuildFailed(
      captureId: "cap_456",
      message: "Pack artifact could not be finalized.",
    );
    final facade.RevclustCapturePersistenceFailed persistenceFailed =
        facade.RevclustCapturePersistenceFailed(
      captureId: "cap_457",
      message: "Pending queue persistence failed.",
    );
    final facade.RevclustUploadAccepted accepted =
        facade.RevclustUploadAccepted(
      captureId: "cap_123",
      result: facade.RevclustAcceptedResult(
        packId: "pack_123",
        schemaVersion: "1.0.0",
        blobBytesGzip: 2048,
        acceptedAt: DateTime.parse("2026-03-27T12:00:00Z"),
        viewerUrl: Uri.parse("https://viewer.revclust.test/incidents/cap_123"),
      ),
    );
    final facade.RevclustUploadRejected rejected =
        facade.RevclustUploadRejected(
      captureId: "cap_789",
      code: facade.RevclustRejectionCode.invalidRequest,
      message: "Schema payload is missing a required field.",
    );
    final facade.RevclustTransportFailure transportFailure =
        facade.RevclustTransportFailure(
      captureId: "cap_101",
      statusCode: 503,
      message: "Bootstrap upload endpoint unavailable.",
      retryable: true,
    );
    final facade.RevclustUploadSnapshot snapshot =
        facade.RevclustUploadSnapshot(
      pendingCount: 2,
      uploadingCount: 1,
      lastErrorCode: facade.RevclustUploadErrorCode.transportUnavailable,
    );

    expect(config.projectKey, _projectKey);
    expect(config.environment, facade.RevclustEnvironment.staging);
    expect(identity.kind, "order");
    expect(identity.value, "ord_123");
    expect(trigger.reason, "checkout confirmation mismatch");
    expect(trigger.signature, "checkout_confirmation_mismatch");
    expect(trigger.relevantIds["cart_id"], "cart_123");

    expect(queued.captureId, "cap_123");
    expect(buildFailed.captureId, "cap_456");
    expect(persistenceFailed.captureId, "cap_457");
    expect(
      (blocked as facade.RevclustCaptureBlocked).status,
      facade.RevclustStatus.misconfigured,
    );

    expect(accepted.captureId, "cap_123");
    expect(accepted.result.packId, "pack_123");
    expect(accepted.result.schemaVersion, "1.0.0");
    expect(rejected.captureId, "cap_789");
    expect(rejected.code, facade.RevclustRejectionCode.invalidRequest);
    expect(transportFailure.captureId, "cap_101");
    expect(transportFailure.retryable, isTrue);

    expect(snapshot.pendingCount, 2);
    expect(snapshot.uploadingCount, 1);
    expect(
      snapshot.lastErrorCode,
      facade.RevclustUploadErrorCode.transportUnavailable,
    );
  });

  test(
      "partner-facing initialize returns a degraded app-scoped facade by default",
      () async {
    facade_internal.RevclustFacadeTestSupport.bootstrapProbe =
        _FakeBootstrapProbe(
      (_) async => const facade_internal
          .RevclustBootstrapAssessment.bootstrapUnavailable(
        message: "Bootstrap is unavailable.",
      ),
    );

    final facade.Revclust first = await facade.Revclust.initialize(
      facade.RevclustConfig(projectKey: _projectKey),
    );
    final facade.Revclust second = await facade.Revclust.initialize(
      facade.RevclustConfig(projectKey: _projectKey),
    );

    expect(second, same(first));
    expect(first.status, facade.RevclustStatus.degraded);
    expect(first.uploadSnapshot.pendingCount, 0);
    expect(first.uploadSnapshot.uploadingCount, 0);
    expect(
      first.uploadSnapshot.lastErrorCode,
      facade.RevclustUploadErrorCode.transportUnavailable,
    );
    expect(first.uploadEvents.isBroadcast, isTrue);
  });

  test("local storage scope ids stay stable for project hashing", () {
    final facade.RevclustConfig config = facade.RevclustConfig(
      projectKey: _projectKey,
      environment: facade.RevclustEnvironment.development,
    );

    expect(
      facade_internal.RevclustFacadeTestSupport.localStorageDatabaseFileName(
        config,
      ),
      "revclust_public_facade_development_4be5469f7d1c900b.db",
    );
    expect(
      facade_internal.RevclustFacadeTestSupport.localStorageKey(config),
      "revclust_public_facade_encryption_key_development_4be5469f7d1c900b",
    );
  });

  test(
      "production local persistence resolver yields a working desktop database factory",
      () async {
    if (!isRevclustSupportedDesktopRuntime) {
      return;
    }

    final Directory tempDirectory = await Directory.systemTemp.createTemp(
      "revclust_public_facade_runtime_db_",
    );
    final low_level.LocalPackRepository repository =
        low_level.LocalPackRepository(
      encryptionService: low_level.AesGcmEncryptionService(
        keyStore: InMemoryKeyStore(),
      ),
      databasePath: "${tempDirectory.path}/facade_runtime.db",
      databaseFactory: resolveRevclustDatabaseFactory(),
    );

    try {
      await repository.savePending(
        low_level.PackBuildResult(
          payload: const <String, Object?>{"capture_id": "cap_runtime_001"},
          gzipBytes: Uint8List.fromList(<int>[1, 2, 3]),
          truncated: false,
          droppedCountsByType: const <String, int>{},
          droppedBytes: 0,
        ),
      );

      final low_level.LocalPackRecord? record =
          await repository.getById("cap_runtime_001");
      expect(record, isNotNull);
      expect(await repository.countPending(), 1);
    } finally {
      await repository.close();
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    }
  });

  test("partner-facing state snapshot provider stays sync-only", () {
    facade.RevclustStateSnapshot syncProvider() {
      return const facade.RevclustStateSnapshot(
        appState: <String, Object?>{"screen": "checkout"},
      );
    }

    Future<facade.RevclustStateSnapshot> asyncProvider() async {
      return const facade.RevclustStateSnapshot(
        dataState: <String, Object?>{"order_id": "ord_123"},
      );
    }

    final facade.RevclustStateSnapshotProvider provider = syncProvider;
    final Object asyncProviderAsObject = asyncProvider;

    expect(provider().appState["screen"], "checkout");
    expect(
      () => asyncProviderAsObject as facade.RevclustStateSnapshotProvider,
      throwsA(isA<TypeError>()),
    );
  });

  test("legacy low-level entrypoint remains available", () {
    final low_level.SdkConfig config = low_level.SdkConfig();
    final low_level.RevclustSdk sdk = low_level.RevclustSdk(config: config);

    expect(config.enabled, isTrue);
    expect(sdk.config, same(config));
  });

  test("acceptedAt stays aligned with SDK-observed acceptance time", () async {
    final DateTime observedAt = DateTime.parse("2026-03-28T15:30:00Z");
    final Dio dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest:
              (RequestOptions options, RequestInterceptorHandler handler) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 202,
                data: <String, Object?>{
                  "accepted": true,
                  "pack_id": "ppk_accept_001",
                  "schema_version": "1.0.0",
                  "blob_bytes_gzip": 128,
                },
              ),
            );
          },
        ),
      );
    final upload_internal.HttpRevclustOwnedUploadTransport transport =
        upload_internal.HttpRevclustOwnedUploadTransport(
      dio: dio,
      utcNow: () => observedAt,
    );

    final upload_internal.RevclustOwnedUploadTransportResult result =
        await transport.upload(
      claimedPack: low_level.LocalPackRecord(
        captureId: "cap_accepted_001",
        createdAtUtcMs: 1000,
        gzipBytes: Uint8List.fromList(<int>[1, 2, 3]),
        status: low_level.LocalPackRepository.statusUploading,
      ),
      lease: facade_internal.RevclustBootstrapLease(
        uploadEndpoint: Uri.parse("https://revclust.com/api/pilot/packs"),
        authToken: "pilot_upload_auth_live",
        usableUntil: DateTime.parse("2030-01-01T00:00:00Z"),
        viewerBaseUrl: Uri.parse("https://revclust.com/pilot/packs"),
      ),
    );

    expect(result, isA<upload_internal.RevclustOwnedUploadAccepted>());
    expect(
      (result as upload_internal.RevclustOwnedUploadAccepted).result.acceptedAt,
      observedAt,
    );
  });
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
