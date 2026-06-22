import "dart:convert";
import "dart:typed_data";

import "package:sqflite/sqflite.dart" as sqflite;

import "../observability/sdk_logger.dart";
import "../pack/pack_build_result.dart";
import "aes_gcm_encryption_service.dart";

/// Decrypted local pack row.
class LocalPackRecord {
  LocalPackRecord({
    required this.captureId,
    required this.createdAtUtcMs,
    required Uint8List gzipBytes,
    required this.status,
    this.attemptCount = 0,
    this.nextAttemptAtUtcMs,
    this.claimedAtUtcMs,
    this.lastErrorCode,
  }) : gzipBytes = Uint8List.fromList(gzipBytes);

  final String captureId;
  final int createdAtUtcMs;
  final Uint8List gzipBytes;
  final String status;
  final int attemptCount;
  final int? nextAttemptAtUtcMs;
  final int? claimedAtUtcMs;
  final String? lastErrorCode;
}

/// Aggregate queue counts used by the hosted public facade uploader.
final class LocalPackQueueState {
  const LocalPackQueueState({
    required this.pendingCount,
    required this.uploadingCount,
  });

  final int pendingCount;
  final int uploadingCount;
}

/// Adjacent metadata stored for a pending public-facade capture.
class LocalPendingCaptureMetadata {
  LocalPendingCaptureMetadata({
    required String captureId,
    required String failureKind,
    required String subjectKind,
    required String subjectValue,
  })  : captureId = LocalPackRepository._normalizeRequiredString(
            captureId, "captureId"),
        failureKind = LocalPackRepository._normalizeRequiredString(
          failureKind,
          "failureKind",
        ),
        subjectKind = LocalPackRepository._normalizeRequiredString(
          subjectKind,
          "subjectKind",
        ),
        subjectValue = LocalPackRepository._normalizeRequiredString(
          subjectValue,
          "subjectValue",
        );

  final String captureId;
  final String failureKind;
  final String subjectKind;
  final String subjectValue;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      "capture_id": captureId,
      "failure_kind": failureKind,
      "subject": <String, Object?>{
        "kind": subjectKind,
        "value": subjectValue,
      },
    };
  }

  factory LocalPendingCaptureMetadata.fromJson(Map<String, Object?> json) {
    final Map<String, Object?>? subject = json["subject"] == null
        ? null
        : LocalPackRepository._requireObjectMap(
            json["subject"],
            "subject",
          );
    final Map<String, Object?>? legacyIdentity = json["identity"] == null
        ? null
        : LocalPackRepository._requireObjectMap(
            json["identity"],
            "identity",
          );
    final Map<String, Object?> resolvedSubject =
        subject ?? legacyIdentity ?? <String, Object?>{};
    final Object? rawFailureKind =
        json["failure_kind"] ?? json["signature"] ?? json["reason"];
    return LocalPendingCaptureMetadata(
      captureId: LocalPackRepository._requireString(
        json["capture_id"],
        "capture_id",
      ),
      failureKind: rawFailureKind == null
          ? "legacy_capture"
          : LocalPackRepository._requireString(
              rawFailureKind,
              "failure_kind",
            ),
      subjectKind: LocalPackRepository._requireString(
        resolvedSubject["kind"],
        "subject.kind",
      ),
      subjectValue: LocalPackRepository._requireString(
        resolvedSubject["value"],
        "subject.value",
      ),
    );
  }
}

/// Encrypted local SQLite persistence for pack gzip artifacts.
class LocalPackRepository {
  LocalPackRepository({
    required AesGcmEncryptionService encryptionService,
    required String databasePath,
    sqflite.DatabaseFactory? databaseFactory,
    int Function()? utcNowMs,
    SdkLogger? logger,
  })  : _encryptionService = encryptionService,
        _databasePath = _normalizeRequiredString(databasePath, "databasePath"),
        _databaseFactory = databaseFactory ?? sqflite.databaseFactory,
        _utcNowMs =
            utcNowMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch),
        _logger = logger;

  static const String tableName = "revclust_local_packs";
  static const String pendingMetadataTableName =
      "revclust_pending_capture_metadata";
  static const int _databaseVersion = 3;

  static const String statusPending = "pending";
  static const String statusUploading = "uploading";
  static const String statusUploaded = "uploaded";
  static const String statusFailed = "failed";

  final AesGcmEncryptionService _encryptionService;
  final String _databasePath;
  final sqflite.DatabaseFactory _databaseFactory;
  final int Function() _utcNowMs;
  final SdkLogger? _logger;

  sqflite.Database? _database;
  bool _isClosed = false;

  Future<void> savePending(PackBuildResult result) {
    return savePendingWithMetadata(result);
  }

  Future<void> savePendingWithMetadata(
    PackBuildResult result, {
    LocalPendingCaptureMetadata? metadata,
  }) async {
    String stage = "extract_capture_id";
    String? captureId;
    try {
      captureId = _extractCaptureId(result.payload);
      if (metadata != null && metadata.captureId != captureId) {
        throw ArgumentError.value(
          metadata.captureId,
          "metadata.captureId",
          "must match payload.capture_id",
        );
      }
      stage = "validate_clock";
      final int createdAtUtcMs = _utcNowMs();
      if (createdAtUtcMs < 0) {
        throw StateError("created_at must be >= 0.");
      }

      stage = "encrypt_blob";
      final Uint8List cipherBlob = await _encryptionService.encrypt(
        result.gzipBytes,
      );
      stage = "open_database";
      final sqflite.Database database = await _openDatabase();
      Uint8List? cipherMetadataBlob;
      if (metadata != null) {
        stage = "encrypt_metadata";
        cipherMetadataBlob = await _encryptMetadata(metadata);
      }
      stage = "persist_transaction";
      await database.transaction((sqflite.Transaction txn) async {
        await txn.insert(
          tableName,
          <String, Object?>{
            "id": captureId,
            "created_at": createdAtUtcMs,
            "cipher_blob": cipherBlob,
            "status": statusPending,
            "attempt_count": 0,
            "next_attempt_at": createdAtUtcMs,
            "claimed_at": null,
            "last_error_code": null,
          },
          conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
        );
        if (cipherMetadataBlob == null) {
          await txn.delete(
            pendingMetadataTableName,
            where: "capture_id = ?",
            whereArgs: <Object?>[captureId],
          );
          return;
        }
        await txn.insert(
          pendingMetadataTableName,
          <String, Object?>{
            "capture_id": captureId,
            "created_at": createdAtUtcMs,
            "cipher_blob": cipherMetadataBlob,
          },
          conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
        );
      });
    } catch (error, stackTrace) {
      _logger?.call(
        SdkLogEntry(
          level: SdkLogLevel.error,
          code: SdkLogCodes.localPersistenceFailed,
          message: "Local pack persistence failed.",
          metadata: <String, Object?>{
            if (captureId != null) "capture_id": captureId,
            "error_type": error.runtimeType.toString(),
            "stage": stage,
          },
          stackTrace: stackTrace,
        ),
      );
      rethrow;
    }
  }

  Future<List<LocalPackRecord>> listPending({int? limit}) async {
    if (limit != null && limit <= 0) {
      throw ArgumentError.value(limit, "limit", "must be > 0");
    }

    final sqflite.Database database = await _openDatabase();
    final List<Map<String, Object?>> rows = await database.query(
      tableName,
      where: "status = ?",
      whereArgs: <Object?>[statusPending],
      orderBy: "created_at ASC",
      limit: limit,
    );
    return _decodeRows(rows);
  }

  Future<int> countPending() async {
    return (await describeQueue()).pendingCount;
  }

  Future<int> countUploading() async {
    return (await describeQueue()).uploadingCount;
  }

  Future<LocalPackQueueState> describeQueue() async {
    final sqflite.Database database = await _openDatabase();
    final List<Map<String, Object?>> rows = await database.rawQuery(
      """
SELECT
  COALESCE(SUM(CASE WHEN status = ? THEN 1 ELSE 0 END), 0) AS pending_count,
  COALESCE(SUM(CASE WHEN status = ? THEN 1 ELSE 0 END), 0) AS uploading_count
FROM $tableName
""",
      <Object?>[
        statusPending,
        statusUploading,
      ],
    );
    if (rows.isEmpty) {
      return const LocalPackQueueState(
        pendingCount: 0,
        uploadingCount: 0,
      );
    }
    final Map<String, Object?> row = rows.single;
    return LocalPackQueueState(
      pendingCount: _requireNonNegativeInt(
        row["pending_count"],
        "pending_count",
      ),
      uploadingCount: _requireNonNegativeInt(
        row["uploading_count"],
        "uploading_count",
      ),
    );
  }

  Future<void> markUploaded(
    String captureId, {
    int attemptsUsed = 0,
  }) async {
    await _finalizeStatus(
      captureId,
      statusUploaded,
      attemptsUsed: attemptsUsed,
    );
  }

  Future<void> markFailed(
    String captureId, {
    String? lastErrorCode,
    int attemptsUsed = 0,
  }) async {
    await _finalizeStatus(
      captureId,
      statusFailed,
      lastErrorCode: lastErrorCode,
      attemptsUsed: attemptsUsed,
    );
  }

  Future<LocalPackRecord?> claimNextUploadable() async {
    final int nowUtcMs = _utcNowMs();
    if (nowUtcMs < 0) {
      throw StateError("claim time must be >= 0.");
    }
    final sqflite.Database database = await _openDatabase();
    Map<String, Object?>? claimedRow;
    await database.transaction((sqflite.Transaction txn) async {
      final List<Map<String, Object?>> rows = await txn.query(
        tableName,
        where: "status = ? AND next_attempt_at <= ?",
        whereArgs: <Object?>[
          statusPending,
          nowUtcMs,
        ],
        orderBy: "next_attempt_at ASC, created_at ASC",
        limit: 1,
      );
      if (rows.isEmpty) {
        return;
      }

      final Map<String, Object?> existing = rows.single;
      final String captureId = _requireString(existing["id"], "id");
      await txn.update(
        tableName,
        <String, Object?>{
          "status": statusUploading,
          "claimed_at": nowUtcMs,
        },
        where: "id = ?",
        whereArgs: <Object?>[captureId],
      );

      final List<Map<String, Object?>> updatedRows = await txn.query(
        tableName,
        where: "id = ?",
        whereArgs: <Object?>[captureId],
        limit: 1,
      );
      if (updatedRows.isNotEmpty) {
        claimedRow = updatedRows.single;
      }
    });

    final Map<String, Object?>? row = claimedRow;
    if (row == null) {
      return null;
    }
    return _decodeRow(row);
  }

  Future<void> releaseClaimForRetry(
    String captureId, {
    required int nextAttemptAtUtcMs,
    String? lastErrorCode,
    int attemptsUsed = 0,
  }) async {
    final String normalizedId =
        _normalizeRequiredString(captureId, "captureId");
    if (nextAttemptAtUtcMs < 0) {
      throw ArgumentError.value(
        nextAttemptAtUtcMs,
        "nextAttemptAtUtcMs",
        "must be >= 0",
      );
    }
    final String? normalizedErrorCode =
        _normalizeOptionalString(lastErrorCode, "lastErrorCode");
    if (attemptsUsed < 0) {
      throw ArgumentError.value(attemptsUsed, "attemptsUsed", "must be >= 0");
    }
    final sqflite.Database database = await _openDatabase();
    await database.rawUpdate(
      "UPDATE $tableName "
      "SET status = ?, "
      "next_attempt_at = ?, "
      "claimed_at = NULL, "
      "last_error_code = ?, "
      "attempt_count = attempt_count + ? "
      "WHERE id = ?",
      <Object?>[
        statusPending,
        nextAttemptAtUtcMs,
        normalizedErrorCode,
        attemptsUsed,
        normalizedId,
      ],
    );
  }

  Future<int> requeueExpiredClaims({
    required int claimLeaseMs,
  }) async {
    if (claimLeaseMs <= 0) {
      throw ArgumentError.value(claimLeaseMs, "claimLeaseMs", "must be > 0");
    }
    final int staleBeforeUtcMs = _utcNowMs() - claimLeaseMs;
    final sqflite.Database database = await _openDatabase();
    return database.update(
      tableName,
      <String, Object?>{
        "status": statusPending,
        "next_attempt_at": staleBeforeUtcMs + claimLeaseMs,
        "claimed_at": null,
      },
      where: "status = ? AND claimed_at IS NOT NULL AND claimed_at <= ?",
      whereArgs: <Object?>[
        statusUploading,
        staleBeforeUtcMs,
      ],
    );
  }

  Future<int?> nextPendingAttemptAt() async {
    final sqflite.Database database = await _openDatabase();
    final List<Map<String, Object?>> rows = await database.rawQuery(
      "SELECT MIN(next_attempt_at) AS next_attempt_at FROM $tableName "
      "WHERE status = ?",
      <Object?>[statusPending],
    );
    if (rows.isEmpty) {
      return null;
    }
    final Object? rawValue = rows.single["next_attempt_at"];
    if (rawValue == null) {
      return null;
    }
    return _requireNonNegativeInt(rawValue, "next_attempt_at");
  }

  Future<int?> nextClaimExpiryAt({
    required int claimLeaseMs,
  }) async {
    if (claimLeaseMs <= 0) {
      throw ArgumentError.value(claimLeaseMs, "claimLeaseMs", "must be > 0");
    }
    final sqflite.Database database = await _openDatabase();
    final List<Map<String, Object?>> rows = await database.rawQuery(
      "SELECT MIN(claimed_at + ?) AS claim_expiry_at FROM $tableName "
      "WHERE status = ? AND claimed_at IS NOT NULL",
      <Object?>[
        claimLeaseMs,
        statusUploading,
      ],
    );
    if (rows.isEmpty) {
      return null;
    }
    final Object? rawValue = rows.single["claim_expiry_at"];
    if (rawValue == null) {
      return null;
    }
    return _requireNonNegativeInt(rawValue, "claim_expiry_at");
  }

  Future<LocalPendingCaptureMetadata?> getPendingMetadata(
    String captureId,
  ) async {
    final String normalizedId =
        _normalizeRequiredString(captureId, "captureId");
    final sqflite.Database database = await _openDatabase();
    final List<Map<String, Object?>> rows = await database.query(
      pendingMetadataTableName,
      where: "capture_id = ?",
      whereArgs: <Object?>[normalizedId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return _decodeMetadataRow(rows.single);
  }

  Future<LocalPackRecord?> getById(String captureId) async {
    final String normalizedId =
        _normalizeRequiredString(captureId, "captureId");
    final sqflite.Database database = await _openDatabase();
    final List<Map<String, Object?>> rows = await database.query(
      tableName,
      where: "id = ?",
      whereArgs: <Object?>[normalizedId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return _decodeRow(rows.single);
  }

  Future<Uint8List?> decryptById(String captureId) async {
    final LocalPackRecord? row = await getById(captureId);
    return row?.gzipBytes;
  }

  Future<void> close() async {
    _isClosed = true;
    final sqflite.Database? database = _database;
    if (database == null) {
      return;
    }
    _database = null;
    await database.close();
  }

  Future<void> _finalizeStatus(
    String captureId,
    String status, {
    String? lastErrorCode,
    int attemptsUsed = 0,
  }) async {
    final String normalizedId =
        _normalizeRequiredString(captureId, "captureId");
    final String? normalizedErrorCode =
        _normalizeOptionalString(lastErrorCode, "lastErrorCode");
    if (attemptsUsed < 0) {
      throw ArgumentError.value(attemptsUsed, "attemptsUsed", "must be >= 0");
    }
    final sqflite.Database database = await _openDatabase();
    await database.transaction((sqflite.Transaction txn) async {
      await txn.rawUpdate(
        "UPDATE $tableName "
        "SET status = ?, "
        "claimed_at = NULL, "
        "last_error_code = ?, "
        "attempt_count = attempt_count + ? "
        "WHERE id = ?",
        <Object?>[
          status,
          normalizedErrorCode,
          attemptsUsed,
          normalizedId,
        ],
      );
      await txn.delete(
        pendingMetadataTableName,
        where: "capture_id = ?",
        whereArgs: <Object?>[normalizedId],
      );
    });
  }

  Future<List<LocalPackRecord>> _decodeRows(
    List<Map<String, Object?>> rows,
  ) async {
    final List<LocalPackRecord> decoded = <LocalPackRecord>[];
    for (final Map<String, Object?> row in rows) {
      decoded.add(await _decodeRow(row));
    }
    return List<LocalPackRecord>.unmodifiable(decoded);
  }

  Future<LocalPackRecord> _decodeRow(Map<String, Object?> row) async {
    final String captureId = _requireString(row["id"], "id");
    final int createdAtUtcMs = _requireNonNegativeInt(
      row["created_at"],
      "created_at",
    );
    final Uint8List cipherBlob =
        _requireBytes(row["cipher_blob"], "cipher_blob");
    final String status = _requireString(row["status"], "status");
    final int attemptCount = _requireNonNegativeInt(
      row["attempt_count"],
      "attempt_count",
    );
    final int nextAttemptAtUtcMs = _requireNonNegativeInt(
      row["next_attempt_at"],
      "next_attempt_at",
    );
    final int? claimedAtUtcMs = _requireOptionalNonNegativeInt(
      row["claimed_at"],
      "claimed_at",
    );
    final String? lastErrorCode = _requireOptionalString(
      row["last_error_code"],
      "last_error_code",
    );
    final Uint8List plainGzipBytes =
        await _encryptionService.decrypt(cipherBlob);

    return LocalPackRecord(
      captureId: captureId,
      createdAtUtcMs: createdAtUtcMs,
      gzipBytes: plainGzipBytes,
      status: status,
      attemptCount: attemptCount,
      nextAttemptAtUtcMs: nextAttemptAtUtcMs,
      claimedAtUtcMs: claimedAtUtcMs,
      lastErrorCode: lastErrorCode,
    );
  }

  Future<LocalPendingCaptureMetadata> _decodeMetadataRow(
    Map<String, Object?> row,
  ) async {
    final Uint8List cipherBlob =
        _requireBytes(row["cipher_blob"], "cipher_blob");
    final Uint8List plainBytes = await _encryptionService.decrypt(cipherBlob);
    final Object? decoded = jsonDecode(utf8.decode(plainBytes));
    final Map<String, Object?> payload = _requireObjectMap(
      decoded,
      "pending_metadata",
    );
    return LocalPendingCaptureMetadata.fromJson(payload);
  }

  Future<Uint8List> _encryptMetadata(
    LocalPendingCaptureMetadata metadata,
  ) async {
    final List<int> encoded = utf8.encode(jsonEncode(metadata.toJson()));
    return _encryptionService.encrypt(Uint8List.fromList(encoded));
  }

  Future<sqflite.Database> _openDatabase() async {
    if (_isClosed) {
      throw StateError("LocalPackRepository is closed.");
    }
    final sqflite.Database? existing = _database;
    if (existing != null) {
      return existing;
    }

    final sqflite.Database opened = await _databaseFactory.openDatabase(
      _databasePath,
      options: sqflite.OpenDatabaseOptions(
        version: _databaseVersion,
        onCreate: (sqflite.Database db, int version) async {
          await _createLocalPacksTable(db);
          await _createPendingMetadataTable(db);
        },
        onUpgrade: (sqflite.Database db, int oldVersion, int newVersion) async {
          if (oldVersion < 2) {
            await _createPendingMetadataTable(db);
          }
          if (oldVersion < 3) {
            await _upgradeLocalPacksTableToVersion3(db);
          }
        },
      ),
    );
    _database = opened;
    return opened;
  }

  Future<void> _createLocalPacksTable(sqflite.DatabaseExecutor db) {
    return db.execute('''
CREATE TABLE $tableName (
  id TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL,
  cipher_blob BLOB NOT NULL,
  status TEXT NOT NULL,
  attempt_count INTEGER NOT NULL,
  next_attempt_at INTEGER NOT NULL,
  claimed_at INTEGER,
  last_error_code TEXT
)
''');
  }

  Future<void> _upgradeLocalPacksTableToVersion3(
    sqflite.DatabaseExecutor db,
  ) async {
    await db.execute(
      "ALTER TABLE $tableName "
      "ADD COLUMN attempt_count INTEGER NOT NULL DEFAULT 0",
    );
    await db.execute(
      "ALTER TABLE $tableName "
      "ADD COLUMN next_attempt_at INTEGER NOT NULL DEFAULT 0",
    );
    await db.execute(
      "ALTER TABLE $tableName "
      "ADD COLUMN claimed_at INTEGER",
    );
    await db.execute(
      "ALTER TABLE $tableName "
      "ADD COLUMN last_error_code TEXT",
    );
    await db.execute(
      "UPDATE $tableName "
      "SET next_attempt_at = created_at "
      "WHERE next_attempt_at = 0",
    );
  }

  Future<void> _createPendingMetadataTable(sqflite.DatabaseExecutor db) {
    return db.execute('''
CREATE TABLE $pendingMetadataTableName (
  capture_id TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL,
  cipher_blob BLOB NOT NULL
)
''');
  }

  static String _extractCaptureId(Map<String, Object?> payload) {
    final Object? rawCaptureId = payload["capture_id"];
    if (rawCaptureId is! String) {
      throw ArgumentError.value(
        rawCaptureId,
        "payload.capture_id",
        "must be a non-empty string",
      );
    }
    return _normalizeRequiredString(rawCaptureId, "payload.capture_id");
  }

  static String _requireString(Object? value, String field) {
    if (value is! String) {
      throw StateError("Invalid DB field `$field`: expected String.");
    }
    return _normalizeRequiredString(value, field);
  }

  static String? _requireOptionalString(Object? value, String field) {
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw StateError("Invalid DB field `$field`: expected String.");
    }
    return _normalizeRequiredString(value, field);
  }

  static Uint8List _requireBytes(Object? value, String field) {
    if (value is Uint8List) {
      return Uint8List.fromList(value);
    }
    if (value is List<int>) {
      return Uint8List.fromList(value);
    }
    throw StateError("Invalid DB field `$field`: expected bytes.");
  }

  static int _requireNonNegativeInt(Object? value, String field) {
    if (value is int && value >= 0) {
      return value;
    }
    throw StateError("Invalid DB field `$field`: expected non-negative int.");
  }

  static int? _requireOptionalNonNegativeInt(Object? value, String field) {
    if (value == null) {
      return null;
    }
    return _requireNonNegativeInt(value, field);
  }

  static Map<String, Object?> _requireObjectMap(Object? value, String field) {
    if (value is Map<Object?, Object?>) {
      return Map<String, Object?>.from(value);
    }
    if (value is Map<String, Object?>) {
      return Map<String, Object?>.from(value);
    }
    throw StateError("Invalid DB field `$field`: expected object map.");
  }

  static String _normalizeRequiredString(String value, String name) {
    final String normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, name, "must not be empty");
    }
    return normalized;
  }

  static String? _normalizeOptionalString(String? value, String name) {
    if (value == null) {
      return null;
    }
    final String normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, name, "must not be empty");
    }
    return normalized;
  }
}
