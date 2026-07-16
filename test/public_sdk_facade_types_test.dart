import "dart:io";
import "dart:typed_data";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter_sdk/revclust_flutter.dart" as facade;
import "package:revclust_flutter_sdk/revclust_flutter_sdk.dart"
    as compatibility;
import "package:revclust_flutter_sdk/src/internal/revclust_internal.dart"
    as low_level;
import "package:revclust_flutter_sdk/src/persistence/revclust_database_factory.dart";
import "package:revclust_flutter_sdk/src/public/revclust_bootstrap.dart"
    as bootstrap_internal;
import "package:revclust_flutter_sdk/src/public/revclust.dart"
    as facade_internal;
import "package:revclust_flutter_sdk/src/public/revclust_owned_upload.dart"
    as upload_internal;

import "support/in_memory_key_store.dart";
import "support/public_facade_local_capture_factory.dart";

// Deliberately synthetic shape-valid test key; never use this outside tests.
const String _sdkKey = "rpk_00000000000000000000000000000000";

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

  test("public entrypoint exposes SDK types", () {
    final facade.RevclustConfig config = facade.RevclustConfig(
      projectKey: _sdkKey,
      releaseStage: facade.RevclustAppReleaseStage.staging,
      appVersion: " 1.2.3 ",
      build: " 1203 ",
      gitSha: "ABCDEF1",
    );
    final facade.RevclustSubject subject = facade.RevclustSubject(
      kind: "order_ref",
      value: "ord_123",
    );
    final facade.RevclustInvariantFailure failure =
        facade.RevclustInvariantFailure(
      failureKind: "checkout_confirmation_mismatch",
      subject: subject,
      expected: const <String, Object?>{"order_status": "confirmed"},
      observed: const <String, Object?>{"order_status": "retrying"},
    );
    final facade.RevclustCaptureQueued queued =
        facade.RevclustCaptureQueued(captureId: "cap_123");
    final facade.RevclustCaptureOutcome blocked = facade.RevclustCaptureBlocked(
      status: facade.RevclustStatus.misconfigured,
      message: "SDK key is not available.",
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

    expect(config.projectKey, _sdkKey);
    expect(config.releaseStage, facade.RevclustAppReleaseStage.staging);
    expect(config.appVersion, "1.2.3");
    expect(config.build, "1203");
    expect(config.gitSha, "abcdef1");
    expect(
      facade.RevclustAppReleaseStage.custom("preview_1").value,
      "preview_1",
    );
    expect(
      () => facade.RevclustAppReleaseStage.custom("Preview 1"),
      throwsA(isA<ArgumentError>()),
    );
    expect(subject.kind, "order_ref");
    expect(subject.value, "ord_123");
    expect(failure.failureKind, "checkout_confirmation_mismatch");
    expect(failure.subject, same(subject));
    expect(failure.expected, const <String, Object?>{
      "order_status": "confirmed",
    });
    expect(failure.observed, const <String, Object?>{
      "order_status": "retrying",
    });

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

  test("compatibility entrypoint exposes the same SDK types", () {
    final compatibility.RevclustInvariantFailure failure =
        compatibility.RevclustInvariantFailure(
      failureKind: "checkout_confirmation_mismatch",
      subject: compatibility.RevclustSubject(
        kind: "order_ref",
        value: "ord_ref_7d82b1",
      ),
      expected: const <String, Object?>{"order_status": "confirmed"},
      observed: const <String, Object?>{"order_status": "retrying"},
    );

    expect(failure.failureKind, "checkout_confirmation_mismatch");
  });

  test("invariant failure validates required factual fields", () {
    facade.RevclustInvariantFailure validFailure() {
      return facade.RevclustInvariantFailure(
        failureKind: "checkout_confirmation_mismatch",
        subject: facade.RevclustSubject(
          kind: "order_ref",
          value: "ord_ref_7d82b1",
        ),
        expected: const <String, Object?>{
          "order_status": "confirmed",
        },
        observed: const <String, Object?>{
          "order_status": "retrying",
        },
      );
    }

    expect(validFailure, returnsNormally);
    expect(
      () => facade.RevclustInvariantFailure(
        failureKind: "Checkout confirmation mismatch",
        subject: facade.RevclustSubject(
          kind: "order_ref",
          value: "ord_ref_7d82b1",
        ),
        expected: const <String, Object?>{"order_status": "confirmed"},
        observed: const <String, Object?>{"order_status": "retrying"},
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => facade.RevclustSubject(kind: "order ref", value: "ord_ref_7d82b1"),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => facade.RevclustSubject(kind: "order_ref", value: " "),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => facade.RevclustSubject(kind: "order_ref", value: "unknown"),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => facade.RevclustSubject(
        kind: "order_ref",
        value: "unsafe value with spaces",
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => facade.RevclustInvariantFailure(
        failureKind: "checkout_confirmation_mismatch",
        subject: facade.RevclustSubject(
          kind: "order_ref",
          value: "ord_ref_7d82b1",
        ),
        expected: const <String, Object?>{},
        observed: const <String, Object?>{"order_status": "retrying"},
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => facade.RevclustInvariantFailure(
        failureKind: "checkout_confirmation_mismatch",
        subject: facade.RevclustSubject(
          kind: "order_ref",
          value: "ord_ref_7d82b1",
        ),
        expected: const <String, Object?>{"order_status": "confirmed"},
        observed: const <String, Object?>{},
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => facade.RevclustInvariantFailure(
        failureKind: "checkout_confirmation_mismatch",
        subject: facade.RevclustSubject(
          kind: "order_ref",
          value: "ord_ref_7d82b1",
        ),
        expected: const <String, Object?>{"Order status": "confirmed"},
        observed: const <String, Object?>{"order_status": "retrying"},
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => facade.RevclustInvariantFailure(
        failureKind: "checkout_confirmation_mismatch",
        subject: facade.RevclustSubject(
          kind: "order_ref",
          value: "ord_ref_7d82b1",
        ),
        expected: <String, Object?>{"order_status": double.nan},
        observed: const <String, Object?>{"order_status": "retrying"},
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => facade.RevclustInvariantFailure(
        failureKind: "checkout_confirmation_mismatch",
        subject: facade.RevclustSubject(
          kind: "order_ref",
          value: "ord_ref_7d82b1",
        ),
        expected: <String, Object?>{"order_status": Object()},
        observed: const <String, Object?>{"order_status": "retrying"},
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => facade.RevclustInvariantFailure(
        failureKind: "checkout_confirmation_mismatch",
        subject: facade.RevclustSubject(
          kind: "order_ref",
          value: "ord_ref_7d82b1",
        ),
        expected: <String, Object?>{
          "order_status": "x".padRight(257, "x"),
        },
        observed: const <String, Object?>{"order_status": "retrying"},
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test("initialize returns a degraded app-scoped client by default", () async {
    facade_internal.RevclustFacadeTestSupport.bootstrapProbe =
        _FakeBootstrapProbe(
      (_) async => const bootstrap_internal
          .RevclustBootstrapAssessment.bootstrapUnavailable(
        message: "Bootstrap is unavailable.",
      ),
    );

    final facade.Revclust first = await facade.Revclust.initialize(
      facade.RevclustConfig(projectKey: _sdkKey),
    );
    final facade.Revclust second = await facade.Revclust.initialize(
      facade.RevclustConfig(projectKey: _sdkKey),
    );

    expect(second, same(first));
    expect(first.status, facade.RevclustStatus.degraded);
    expect(
      first.diagnostics.bootstrap.state,
      facade.RevclustBootstrapDiagnosticState.unavailable,
    );
    expect(
      first.diagnostics.bootstrap.bootstrapOrigin,
      Uri.parse("https://revclust.com"),
    );
    expect(first.uploadSnapshot.pendingCount, 0);
    expect(first.uploadSnapshot.uploadingCount, 0);
    expect(
      first.uploadSnapshot.lastErrorCode,
      facade.RevclustUploadErrorCode.transportUnavailable,
    );
    expect(first.uploadEvents.isBroadcast, isTrue);
  });

  test("local storage scope ids stay stable for SDK key hashing", () {
    final facade.RevclustConfig config =
        facade.RevclustConfig(projectKey: _sdkKey);

    expect(
      facade_internal.RevclustFacadeTestSupport.localStorageDatabaseFileName(
        config,
      ),
      "revclust_public_facade_ca50da2a78f75d99.db",
    );
    expect(
      facade_internal.RevclustFacadeTestSupport.localStorageKey(config),
      "revclust_public_facade_encryption_key_ca50da2a78f75d99",
    );
  });

  test("local storage scope ignores build metadata", () {
    final facade.RevclustConfig first = facade.RevclustConfig(
      projectKey: _sdkKey,
      releaseStage: facade.RevclustAppReleaseStage.production,
      appVersion: "1.2.3",
      build: "1203",
      gitSha: "abcdef1",
    );
    final facade.RevclustConfig second = facade.RevclustConfig(
      projectKey: _sdkKey,
      releaseStage: facade.RevclustAppReleaseStage.staging,
      appVersion: "1.2.4",
      build: "1204",
      gitSha: "abcdef2",
    );

    expect(first, isNot(second));
    expect(
      facade_internal.RevclustFacadeTestSupport.localStorageDatabaseFileName(
        first,
      ),
      facade_internal.RevclustFacadeTestSupport.localStorageDatabaseFileName(
        second,
      ),
    );
    expect(
      facade_internal.RevclustFacadeTestSupport.localStorageKey(first),
      facade_internal.RevclustFacadeTestSupport.localStorageKey(second),
    );
  });

  test("config rejects invalid build metadata", () {
    expect(
      () => facade.RevclustConfig(projectKey: _sdkKey, appVersion: "   "),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => facade.RevclustConfig(projectKey: _sdkKey, build: "   "),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => facade.RevclustConfig(projectKey: _sdkKey, gitSha: "   "),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => facade.RevclustConfig(projectKey: _sdkKey, gitSha: "not-a-sha"),
      throwsA(isA<ArgumentError>()),
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

  test("state snapshot provider stays sync-only", () {
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

  test("internal low-level entrypoint remains available for SDK tests", () {
    final low_level.SdkConfig config = low_level.SdkConfig();
    final low_level.RevclustSdk sdk = low_level.RevclustSdk(config: config);

    expect(config.enabled, isTrue);
    expect(sdk.config, same(config));
  });

  test("acceptedAt stays aligned with SDK-observed acceptance time", () async {
    final DateTime observedAt = DateTime.parse("2026-03-28T15:30:00Z");
    late RequestOptions uploadRequestOptions;
    final Dio dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest:
              (RequestOptions options, RequestInterceptorHandler handler) {
            uploadRequestOptions = options;
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
      lease: bootstrap_internal.RevclustBootstrapLease(
        uploadEndpoint: Uri.parse("https://revclust.com/api/incident-packs"),
        authToken: "incident_upload_auth_live",
        usableUntil: DateTime.parse("2030-01-01T00:00:00Z"),
        viewerBaseUrl: Uri.parse("https://revclust.com/app/incidents"),
      ),
    );

    expect(result, isA<upload_internal.RevclustOwnedUploadAccepted>());
    expect(
      (result as upload_internal.RevclustOwnedUploadAccepted).result.acceptedAt,
      observedAt,
    );
    expect(
      uploadRequestOptions.headers["authorization"],
      "Bearer incident_upload_auth_live",
    );
  });

  test("expired and used upload leases are mapped to auth rejections",
      () async {
    for (final String code in <String>[
      "upload_authorization_expired",
      "upload_authorization_used",
    ]) {
      final Dio dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest:
                (RequestOptions options, RequestInterceptorHandler handler) {
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 403,
                  data: <String, Object?>{
                    "ok": false,
                    "error": <String, Object?>{
                      "code": code,
                      "message": "Upload authorization is stale.",
                    },
                  },
                ),
              );
            },
          ),
        );
      final upload_internal.HttpRevclustOwnedUploadTransport transport =
          upload_internal.HttpRevclustOwnedUploadTransport(dio: dio);

      final upload_internal.RevclustOwnedUploadTransportResult result =
          await transport.upload(
        claimedPack: low_level.LocalPackRecord(
          captureId: "cap_${code}_001",
          createdAtUtcMs: 1000,
          gzipBytes: Uint8List.fromList(<int>[1, 2, 3]),
          status: low_level.LocalPackRepository.statusUploading,
        ),
        lease: bootstrap_internal.RevclustBootstrapLease(
          uploadEndpoint: Uri.parse("https://revclust.com/api/incident-packs"),
          authToken: "incident_upload_auth_stale",
          usableUntil: DateTime.parse("2030-01-01T00:00:00Z"),
        ),
      );

      expect(result, isA<upload_internal.RevclustOwnedUploadRejected>());
      final upload_internal.RevclustOwnedUploadRejected rejected =
          result as upload_internal.RevclustOwnedUploadRejected;
      expect(rejected.code, facade.RevclustRejectionCode.auth);
      expect(rejected.errorCode, facade.RevclustUploadErrorCode.auth);
    }
  });

  test("quota rejection is explicit and non-auth", () async {
    final Dio dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest:
              (RequestOptions options, RequestInterceptorHandler handler) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 402,
                data: <String, Object?>{
                  "ok": false,
                  "error": <String, Object?>{
                    "code": "quota_exceeded",
                    "message": "Monthly captured incident quota reached.",
                  },
                },
              ),
            );
          },
        ),
      );
    final upload_internal.HttpRevclustOwnedUploadTransport transport =
        upload_internal.HttpRevclustOwnedUploadTransport(dio: dio);

    final upload_internal.RevclustOwnedUploadTransportResult result =
        await transport.upload(
      claimedPack: low_level.LocalPackRecord(
        captureId: "cap_quota_001",
        createdAtUtcMs: 1000,
        gzipBytes: Uint8List.fromList(<int>[1, 2, 3]),
        status: low_level.LocalPackRepository.statusUploading,
      ),
      lease: bootstrap_internal.RevclustBootstrapLease(
        uploadEndpoint: Uri.parse("https://revclust.com/api/incident-packs"),
        authToken: "incident_upload_auth_quota",
        usableUntil: DateTime.parse("2030-01-01T00:00:00Z"),
      ),
    );

    expect(result, isA<upload_internal.RevclustOwnedUploadRejected>());
    final upload_internal.RevclustOwnedUploadRejected rejected =
        result as upload_internal.RevclustOwnedUploadRejected;
    expect(rejected.code, facade.RevclustRejectionCode.quotaExceeded);
    expect(rejected.errorCode, facade.RevclustUploadErrorCode.quotaExceeded);
  });

  test("billing sync is surfaced as a deferred upload with Retry-After",
      () async {
    const String message =
        "Workspace billing is still syncing. Retry this incident pack upload shortly.";
    final Dio dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest:
              (RequestOptions options, RequestInterceptorHandler handler) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 503,
                headers: Headers.fromMap(
                  <String, List<String>>{
                    "retry-after": <String>["17"],
                  },
                ),
                data: <String, Object?>{
                  "ok": false,
                  "error": <String, Object?>{
                    "code": "billing_sync_required",
                    "message": message,
                  },
                },
              ),
            );
          },
        ),
      );
    final upload_internal.HttpRevclustOwnedUploadTransport transport =
        upload_internal.HttpRevclustOwnedUploadTransport(dio: dio);

    final upload_internal.RevclustOwnedUploadTransportResult result =
        await transport.upload(
      claimedPack: low_level.LocalPackRecord(
        captureId: "cap_billing_sync_001",
        createdAtUtcMs: 1000,
        gzipBytes: Uint8List.fromList(<int>[1, 2, 3]),
        status: low_level.LocalPackRepository.statusUploading,
      ),
      lease: bootstrap_internal.RevclustBootstrapLease(
        uploadEndpoint: Uri.parse("https://revclust.com/api/incident-packs"),
        authToken: "incident_upload_auth_billing_sync",
        usableUntil: DateTime.parse("2030-01-01T00:00:00Z"),
      ),
    );

    expect(
      result,
      isA<upload_internal.RevclustOwnedUploadDeferred>(),
    );
    final upload_internal.RevclustOwnedUploadDeferred deferred =
        result as upload_internal.RevclustOwnedUploadDeferred;
    expect(
      deferred.errorCode,
      facade.RevclustUploadErrorCode.transportUnavailable,
    );
    expect(deferred.code, "billing_sync_required");
    expect(deferred.retryAfter, const Duration(seconds: 17));
    expect(deferred.statusCode, 503);
    expect(deferred.message, message);
  });

  test("app remediation defaults missing or invalid Retry-After to 60 seconds",
      () async {
    for (final String? retryAfter in <String?>[null, "0", "later"]) {
      final Dio dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest:
                (RequestOptions options, RequestInterceptorHandler handler) {
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 409,
                  headers: retryAfter == null
                      ? Headers()
                      : Headers.fromMap(
                          <String, List<String>>{
                            "retry-after": <String>[retryAfter],
                          },
                        ),
                  data: <String, Object?>{
                    "ok": false,
                    "error": <String, Object?>{
                      "code": "app_limit_remediation_required",
                      "message": "Archive apps before capturing again.",
                    },
                  },
                ),
              );
            },
          ),
        );
      final upload_internal.HttpRevclustOwnedUploadTransport transport =
          upload_internal.HttpRevclustOwnedUploadTransport(dio: dio);

      final upload_internal.RevclustOwnedUploadTransportResult result =
          await transport.upload(
        claimedPack: low_level.LocalPackRecord(
          captureId: "cap_app_remediation_${retryAfter ?? 'missing'}",
          createdAtUtcMs: 1000,
          gzipBytes: Uint8List.fromList(<int>[1, 2, 3]),
          status: low_level.LocalPackRepository.statusUploading,
        ),
        lease: bootstrap_internal.RevclustBootstrapLease(
          uploadEndpoint: Uri.parse("https://revclust.com/api/incident-packs"),
          authToken: "incident_upload_auth_app_remediation",
          usableUntil: DateTime.parse("2030-01-01T00:00:00Z"),
        ),
      );

      expect(result, isA<upload_internal.RevclustOwnedUploadDeferred>());
      final upload_internal.RevclustOwnedUploadDeferred deferred =
          result as upload_internal.RevclustOwnedUploadDeferred;
      expect(deferred.code, "app_limit_remediation_required");
      expect(deferred.retryAfter, const Duration(seconds: 60));
      expect(deferred.statusCode, 409);
    }
  });

  test("invalid pack shape is mapped to invalid request", () async {
    final Dio dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest:
              (RequestOptions options, RequestInterceptorHandler handler) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 400,
                data: <String, Object?>{
                  "ok": false,
                  "error": <String, Object?>{
                    "code": "invalid_pack_shape",
                    "message": "Pack shape is invalid.",
                  },
                },
              ),
            );
          },
        ),
      );
    final upload_internal.HttpRevclustOwnedUploadTransport transport =
        upload_internal.HttpRevclustOwnedUploadTransport(dio: dio);

    final upload_internal.RevclustOwnedUploadTransportResult result =
        await transport.upload(
      claimedPack: low_level.LocalPackRecord(
        captureId: "cap_invalid_pack_shape_001",
        createdAtUtcMs: 1000,
        gzipBytes: Uint8List.fromList(<int>[1, 2, 3]),
        status: low_level.LocalPackRepository.statusUploading,
      ),
      lease: bootstrap_internal.RevclustBootstrapLease(
        uploadEndpoint: Uri.parse("https://revclust.com/api/incident-packs"),
        authToken: "incident_upload_auth_invalid_shape",
        usableUntil: DateTime.parse("2030-01-01T00:00:00Z"),
      ),
    );

    expect(result, isA<upload_internal.RevclustOwnedUploadRejected>());
    final upload_internal.RevclustOwnedUploadRejected rejected =
        result as upload_internal.RevclustOwnedUploadRejected;
    expect(rejected.code, facade.RevclustRejectionCode.invalidRequest);
    expect(rejected.errorCode, facade.RevclustUploadErrorCode.invalidRequest);
  });
}

final class _FakeBootstrapProbe
    implements bootstrap_internal.RevclustBootstrapProbe {
  _FakeBootstrapProbe(this._assess);

  final Future<bootstrap_internal.RevclustBootstrapAssessment> Function(
    facade.RevclustConfig config,
  ) _assess;

  @override
  Future<bootstrap_internal.RevclustBootstrapAssessment> assess(
    facade.RevclustConfig config,
  ) {
    return _assess(config);
  }
}
