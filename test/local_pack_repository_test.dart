import "dart:convert";
import "dart:io";

import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter_sdk/src/internal/revclust_internal.dart";
import "package:revclust_flutter_sdk/src/persistence/revclust_database_factory.dart";
import "package:sqflite/sqflite.dart";

import "support/in_memory_key_store.dart";

void main() {
  group("LocalPackRepository", () {
    late Directory tempDirectory;
    late InMemoryKeyStore keyStore;
    late AesGcmEncryptionService encryptionService;
    late int clockMs;
    late String dbPath;
    late LocalPackRepository repository;

    setUp(() async {
      keyStore = InMemoryKeyStore();
      encryptionService = AesGcmEncryptionService(keyStore: keyStore);
      clockMs = 1000;
      tempDirectory = await Directory.systemTemp.createTemp(
        "revclust_local_pack_repo_test_",
      );
      dbPath = "${tempDirectory.path}/packs.db";
      repository = LocalPackRepository(
        encryptionService: encryptionService,
        databasePath: dbPath,
        databaseFactory: resolveRevclustDatabaseFactory(),
        utcNowMs: () => clockMs,
      );
    });

    tearDown(() async {
      await repository.close();
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    test("savePending + listPending returns decrypted row", () async {
      final PackBuildResult result = _buildResult(
        captureId: "capture-1",
        text: "gzip-bytes-1",
      );

      await repository.savePending(result);
      final List<LocalPackRecord> pending = await repository.listPending();

      expect(pending, hasLength(1));
      final LocalPackRecord record = pending.single;
      expect(record.captureId, "capture-1");
      expect(record.status, LocalPackRepository.statusPending);
      expect(record.createdAtUtcMs, 1000);
      expect(record.attemptCount, 0);
      expect(record.nextAttemptAtUtcMs, 1000);
      expect(record.claimedAtUtcMs, isNull);
      expect(record.lastErrorCode, isNull);
      expect(record.gzipBytes, Uint8List.fromList(utf8.encode("gzip-bytes-1")));
    });

    test(
      "upsert duplicate capture_id replaces blob, resets status, refreshes created_at",
      () async {
        await repository.savePending(
          _buildResult(captureId: "dup-id", text: "first"),
        );
        await repository.markUploaded("dup-id");
        clockMs = 2000;

        await repository.savePending(
          _buildResult(captureId: "dup-id", text: "second"),
        );

        final LocalPackRecord? record = await repository.getById("dup-id");
        expect(record, isNotNull);
        expect(record!.captureId, "dup-id");
        expect(record.status, LocalPackRepository.statusPending);
        expect(record.createdAtUtcMs, 2000);
        expect(record.attemptCount, 0);
        expect(record.nextAttemptAtUtcMs, 2000);
        expect(record.claimedAtUtcMs, isNull);
        expect(record.gzipBytes, Uint8List.fromList(utf8.encode("second")));
      },
    );

    test("status transitions pending -> uploaded and pending -> failed",
        () async {
      await repository.savePending(
        _buildResult(captureId: "uploaded-id", text: "blob"),
      );
      await repository.markUploaded("uploaded-id");

      final LocalPackRecord? uploaded = await repository.getById("uploaded-id");
      expect(uploaded, isNotNull);
      expect(uploaded!.status, LocalPackRepository.statusUploaded);
      expect(uploaded.claimedAtUtcMs, isNull);
      expect(await repository.listPending(), isEmpty);

      clockMs = 3000;
      await repository.savePending(
        _buildResult(captureId: "failed-id", text: "blob-2"),
      );
      await repository.markFailed("failed-id");

      final LocalPackRecord? failed = await repository.getById("failed-id");
      expect(failed, isNotNull);
      expect(failed!.status, LocalPackRepository.statusFailed);
      expect(failed.claimedAtUtcMs, isNull);
      expect(await repository.listPending(), isEmpty);
    });

    test("claimNextUploadable marks one retryable row as uploading", () async {
      await repository.savePending(
        _buildResult(captureId: "capture-1", text: "gzip-bytes-1"),
      );

      final LocalPackRecord? claimed = await repository.claimNextUploadable();
      final LocalPackQueueState queueState = await repository.describeQueue();

      expect(claimed, isNotNull);
      expect(claimed!.captureId, "capture-1");
      expect(claimed.status, LocalPackRepository.statusUploading);
      expect(claimed.attemptCount, 0);
      expect(claimed.claimedAtUtcMs, 1000);
      expect(queueState.pendingCount, 0);
      expect(queueState.uploadingCount, 1);
    });

    test(
        "releaseClaimForRetry returns uploading work to pending without burning retries",
        () async {
      await repository.savePending(
        _buildResult(captureId: "capture-1", text: "gzip-bytes-1"),
      );
      await repository.claimNextUploadable();
      clockMs = 1500;

      await repository.releaseClaimForRetry(
        "capture-1",
        nextAttemptAtUtcMs: 5000,
        lastErrorCode: "transportUnavailable",
      );

      final LocalPackRecord? retried = await repository.getById("capture-1");
      final LocalPackQueueState queueState = await repository.describeQueue();

      expect(retried, isNotNull);
      expect(retried!.status, LocalPackRepository.statusPending);
      expect(retried.attemptCount, 0);
      expect(retried.nextAttemptAtUtcMs, 5000);
      expect(retried.claimedAtUtcMs, isNull);
      expect(retried.lastErrorCode, "transportUnavailable");
      expect(queueState.pendingCount, 1);
      expect(queueState.uploadingCount, 0);
    });

    test("releaseClaimForRetry records real upload attempts when provided",
        () async {
      await repository.savePending(
        _buildResult(captureId: "capture-1", text: "gzip-bytes-1"),
      );
      await repository.claimNextUploadable();

      await repository.releaseClaimForRetry(
        "capture-1",
        nextAttemptAtUtcMs: 5000,
        lastErrorCode: "transportUnavailable",
        attemptsUsed: 1,
      );

      final LocalPackRecord? retried = await repository.getById("capture-1");

      expect(retried, isNotNull);
      expect(retried!.attemptCount, 1);
      expect(retried.status, LocalPackRepository.statusPending);
    });

    test(
        "requeueExpiredClaims recovers stale uploading work for restart-safe retry",
        () async {
      await repository.savePending(
        _buildResult(captureId: "capture-1", text: "gzip-bytes-1"),
      );
      await repository.claimNextUploadable();
      clockMs = 2500;

      final int recovered = await repository.requeueExpiredClaims(
        claimLeaseMs: 1000,
      );
      final LocalPackRecord? record = await repository.getById("capture-1");

      expect(recovered, 1);
      expect(record, isNotNull);
      expect(record!.status, LocalPackRepository.statusPending);
      expect(record.attemptCount, 0);
      expect(record.nextAttemptAtUtcMs, 2500);
      expect(record.claimedAtUtcMs, isNull);
    });

    test("nextClaimExpiryAt tracks the earliest uploading lease expiry",
        () async {
      await repository.savePending(
        _buildResult(captureId: "capture-1", text: "gzip-bytes-1"),
      );
      await repository.claimNextUploadable();

      expect(
        await repository.nextClaimExpiryAt(claimLeaseMs: 1000),
        2000,
      );

      await repository.releaseClaimForRetry(
        "capture-1",
        nextAttemptAtUtcMs: 3000,
      );

      expect(
        await repository.nextClaimExpiryAt(claimLeaseMs: 1000),
        isNull,
      );
    });

    test(
        "savePendingWithMetadata persists metadata and countPending tracks rows",
        () async {
      await repository.savePendingWithMetadata(
        _buildResult(captureId: "capture-1", text: "gzip-bytes-1"),
        metadata: LocalPendingCaptureMetadata(
          captureId: "capture-1",
          failureKind: "checkout_confirmation_mismatch",
          subjectKind: "order_ref",
          subjectValue: "ord_123",
        ),
      );

      expect(await repository.countPending(), 1);

      final LocalPendingCaptureMetadata? metadata =
          await repository.getPendingMetadata("capture-1");
      expect(metadata, isNotNull);
      expect(metadata!.failureKind, "checkout_confirmation_mismatch");
      expect(metadata.subjectKind, "order_ref");
      expect(metadata.subjectValue, "ord_123");

      await repository.markUploaded("capture-1");

      expect(await repository.countPending(), 0);
      expect(await repository.getPendingMetadata("capture-1"), isNull);
    });

    test("legacy prose and hint metadata are ignored during decode", () {
      final LocalPendingCaptureMetadata metadata =
          LocalPendingCaptureMetadata.fromJson(<String, Object?>{
        "capture_id": "capture-legacy",
        "signature": "checkout_confirmation_mismatch",
        "identity": <String, Object?>{
          "kind": "order_ref",
          "value": "ord_123",
        },
        "flow": "checkout",
        "screen": "confirmation",
        "step_label": "confirm_order",
        "repro_hint": "Legacy prose should not be surfaced.",
        "relevant_ids": <String, Object?>{
          "cart_id": "cart_123",
        },
      });

      expect(metadata.captureId, "capture-legacy");
      expect(metadata.failureKind, "checkout_confirmation_mismatch");
      expect(metadata.subjectKind, "order_ref");
      expect(metadata.subjectValue, "ord_123");
      expect(metadata.toJson().containsKey("repro_hint"), isFalse);
      expect(metadata.toJson().containsKey("flow"), isFalse);
      expect(metadata.toJson().containsKey("screen"), isFalse);
      expect(metadata.toJson().containsKey("step_label"), isFalse);
      expect(metadata.toJson().containsKey("relevant_ids"), isFalse);
    });

    test("logs structured local persistence failures without leaking blob data",
        () async {
      final List<SdkLogEntry> logs = <SdkLogEntry>[];
      final LocalPackRepository failingRepository = LocalPackRepository(
        encryptionService: encryptionService,
        databasePath: dbPath,
        databaseFactory: _ThrowingDatabaseFactory(),
        utcNowMs: () => clockMs,
        logger: logs.add,
      );

      await expectLater(
        failingRepository.savePending(
          _buildResult(captureId: "capture-1", text: "sensitive-gzip-bytes"),
        ),
        throwsA(isA<StateError>()),
      );

      expect(logs, hasLength(1));
      expect(logs.single.code, SdkLogCodes.localPersistenceFailed);
      expect(logs.single.level, SdkLogLevel.error);
      expect(logs.single.metadata["capture_id"], "capture-1");
      expect(logs.single.metadata["stage"], "open_database");
      expect(
        jsonEncode(logs.single.metadata).contains("sensitive-gzip-bytes"),
        isFalse,
      );
    });

    test(
        "desktop mirrored fallback preserves decryptable pending rows across sessions after keyring loss",
        () async {
      final FileBackedKeyStore firstSessionFallbackKeyStore =
          FileBackedKeyStore(filePath: "$dbPath.key");
      final InMemoryKeyStore firstSessionSecureKeyStore = InMemoryKeyStore();
      final LocalPackRepository firstSessionRepository = LocalPackRepository(
        encryptionService: AesGcmEncryptionService(
          keyStore: DesktopFallbackKeyStore(
            secureStorageKeyStore: firstSessionSecureKeyStore,
            fallbackKeyStore: firstSessionFallbackKeyStore,
          ),
        ),
        databasePath: dbPath,
        databaseFactory: resolveRevclustDatabaseFactory(),
        utcNowMs: () => clockMs,
      );
      repository = firstSessionRepository;

      await firstSessionRepository.savePending(
        _buildResult(captureId: "capture-1", text: "session-continuity"),
      );
      final Uint8List? mirroredKeyMaterial =
          await firstSessionFallbackKeyStore.readKeyMaterial();

      expect(mirroredKeyMaterial, isNotNull);
      expect(
        await firstSessionSecureKeyStore.readKeyMaterial(),
        orderedEquals(mirroredKeyMaterial!),
      );

      await firstSessionRepository.close();

      final LocalPackRepository secondSessionRepository = LocalPackRepository(
        encryptionService: AesGcmEncryptionService(
          keyStore: DesktopFallbackKeyStore(
            secureStorageKeyStore: _ThrowingUnavailableKeyStore(),
            fallbackKeyStore: FileBackedKeyStore(filePath: "$dbPath.key"),
          ),
        ),
        databasePath: dbPath,
        databaseFactory: resolveRevclustDatabaseFactory(),
        utcNowMs: () => clockMs,
      );
      repository = secondSessionRepository;

      final LocalPackRecord? record =
          await secondSessionRepository.getById("capture-1");

      expect(record, isNotNull);
      expect(
        record!.gzipBytes,
        Uint8List.fromList(utf8.encode("session-continuity")),
      );
      expect(await secondSessionRepository.countPending(), 1);
    });
  });
}

PackBuildResult _buildResult({
  required String captureId,
  required String text,
}) {
  return PackBuildResult(
    payload: <String, Object?>{"capture_id": captureId},
    gzipBytes: Uint8List.fromList(utf8.encode(text)),
    truncated: false,
    droppedCountsByType: const <String, int>{},
    droppedBytes: 0,
  );
}

class _ThrowingDatabaseFactory implements DatabaseFactory {
  @override
  Future<Database> openDatabase(
    String path, {
    OpenDatabaseOptions? options,
  }) async {
    throw StateError("simulated database open failure");
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

final class _ThrowingUnavailableKeyStore implements KeyStore {
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
