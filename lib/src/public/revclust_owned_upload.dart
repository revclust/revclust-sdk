import "dart:async";
import "dart:convert";

import "package:dio/dio.dart";

import "../persistence/local_pack_repository.dart";
import "revclust_bootstrap.dart";
import "revclust_upload_event.dart";
import "revclust_upload_snapshot.dart";

/// Fixed retry and lease policy for owned uploads.
final class RevclustOwnedUploadRetryPolicy {
  const RevclustOwnedUploadRetryPolicy({
    this.maxAttempts = 3,
    this.backoffSchedule = const <Duration>[
      Duration(seconds: 5),
      Duration(seconds: 30),
      Duration(minutes: 2),
    ],
    this.claimLease = const Duration(minutes: 2),
    this.blockedPollInterval = const Duration(minutes: 1),
  }) : assert(maxAttempts > 0);

  final int maxAttempts;
  final List<Duration> backoffSchedule;
  final Duration claimLease;
  final Duration blockedPollInterval;

  Duration backoffForAttempt(int attemptCount) {
    if (backoffSchedule.isEmpty) {
      return Duration.zero;
    }
    final int scheduleIndex = attemptCount <= 0 ? 0 : attemptCount - 1;
    final int clampedIndex = scheduleIndex >= backoffSchedule.length
        ? backoffSchedule.length - 1
        : scheduleIndex;
    return backoffSchedule[clampedIndex];
  }
}

sealed class RevclustOwnedUploadTransportResult {
  const RevclustOwnedUploadTransportResult();
}

final class RevclustOwnedUploadAccepted
    extends RevclustOwnedUploadTransportResult {
  const RevclustOwnedUploadAccepted(this.result);

  final RevclustAcceptedResult result;
}

final class RevclustOwnedUploadRejected
    extends RevclustOwnedUploadTransportResult {
  const RevclustOwnedUploadRejected({
    required this.code,
    required this.errorCode,
    this.message,
    this.statusCode,
  });

  final RevclustRejectionCode code;
  final RevclustUploadErrorCode errorCode;
  final String? message;
  final int? statusCode;
}

final class RevclustOwnedUploadTransportFailure
    extends RevclustOwnedUploadTransportResult {
  const RevclustOwnedUploadTransportFailure({
    required this.errorCode,
    required this.retryable,
    this.message,
    this.statusCode,
  });

  final RevclustUploadErrorCode errorCode;
  final bool retryable;
  final String? message;
  final int? statusCode;
}

/// Hosted upload transport used by the single-flight public facade coordinator.
abstract interface class RevclustOwnedUploadTransport {
  Future<RevclustOwnedUploadTransportResult> upload({
    required LocalPackRecord claimedPack,
    required RevclustBootstrapLease lease,
  });
}

/// Default hosted upload transport for the public facade.
final class HttpRevclustOwnedUploadTransport
    implements RevclustOwnedUploadTransport {
  HttpRevclustOwnedUploadTransport({
    Dio? dio,
    DateTime Function()? utcNow,
  })  : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                sendTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 10),
                responseType: ResponseType.json,
                validateStatus: (_) => true,
              ),
            ),
        _utcNow = utcNow ?? (() => DateTime.now().toUtc());

  final Dio _dio;
  final DateTime Function() _utcNow;

  @override
  Future<RevclustOwnedUploadTransportResult> upload({
    required LocalPackRecord claimedPack,
    required RevclustBootstrapLease lease,
  }) async {
    Response<dynamic> response;
    try {
      response = await _dio.postUri(
        lease.uploadEndpoint,
        data: <String, Object?>{
          "metadata": <String, Object?>{
            "capture_id": claimedPack.captureId,
          },
          "blob_b64": base64Encode(claimedPack.gzipBytes),
        },
        options: Options(
          headers: <String, Object?>{
            Headers.acceptHeader: Headers.jsonContentType,
            "authorization": "Bearer ${lease.authToken}",
          },
          contentType: Headers.jsonContentType,
        ),
      );
    } on DioException catch (error) {
      return RevclustOwnedUploadTransportFailure(
        errorCode: RevclustUploadErrorCode.transportUnavailable,
        retryable: _isRetryableStatus(error.response?.statusCode) ||
            error.response == null,
        message: error.message?.trim(),
        statusCode: error.response?.statusCode,
      );
    }

    final Map<String, Object?> body = _asObjectMap(response.data);
    final int? statusCode = response.statusCode;
    final bool accepted = body["accepted"] == true;
    if ((statusCode == 200 || statusCode == 202) && accepted) {
      final String? packId = _readOptionalString(body, "pack_id");
      final String? schemaVersion = _readOptionalString(body, "schema_version");
      final int? blobBytesGzip = _readOptionalInt(body["blob_bytes_gzip"]);
      if (packId != null && schemaVersion != null && blobBytesGzip != null) {
        return RevclustOwnedUploadAccepted(
          RevclustAcceptedResult(
            packId: packId,
            schemaVersion: schemaVersion,
            blobBytesGzip: blobBytesGzip,
            acceptedAt: _utcNow(),
            viewerUrl: _buildViewerUrl(
              viewerBaseUrl: lease.viewerBaseUrl,
              packId: packId,
            ),
          ),
        );
      }
      return const RevclustOwnedUploadTransportFailure(
        errorCode: RevclustUploadErrorCode.internalError,
        retryable: false,
        message: "Hosted upload response was missing accepted fields.",
      );
    }

    final Map<String, Object?>? error = _asObjectMapOrNull(body["error"]);
    final String? code =
        error == null ? null : _readOptionalString(error, "code");
    final String? message =
        error == null ? null : _readOptionalString(error, "message");

    final RevclustOwnedUploadTransportResult? rejection = _mapRejection(
      code: code,
      message: message,
      statusCode: statusCode,
    );
    if (rejection != null) {
      return rejection;
    }

    return RevclustOwnedUploadTransportFailure(
      errorCode: RevclustUploadErrorCode.transportUnavailable,
      retryable: _isRetryableStatus(statusCode),
      message: message ?? "Hosted upload could not be completed.",
      statusCode: statusCode,
    );
  }

  RevclustOwnedUploadTransportResult? _mapRejection({
    required String? code,
    required String? message,
    required int? statusCode,
  }) {
    switch (code) {
      case "missing_upload_authorization":
      case "upload_authorization_invalid":
        return RevclustOwnedUploadRejected(
          code: RevclustRejectionCode.auth,
          errorCode: RevclustUploadErrorCode.auth,
          message: message,
          statusCode: statusCode,
        );
      case "unsupported_schema":
        return RevclustOwnedUploadRejected(
          code: RevclustRejectionCode.unsupportedSchema,
          errorCode: RevclustUploadErrorCode.unsupportedSchema,
          message: message,
          statusCode: statusCode,
        );
      case "blob_too_large":
      case "blob_json_too_large":
        return RevclustOwnedUploadRejected(
          code: RevclustRejectionCode.blobTooLarge,
          errorCode: RevclustUploadErrorCode.blobTooLarge,
          message: message,
          statusCode: statusCode,
        );
      case "misconfigured":
      case "invalid_project_key":
      case "project_not_provisioned":
      case "project_not_found":
        return RevclustOwnedUploadRejected(
          code: RevclustRejectionCode.misconfiguration,
          errorCode: RevclustUploadErrorCode.misconfiguration,
          message: message,
          statusCode: statusCode,
        );
      case "unsupported_content_type":
      case "invalid_json_body":
      case "malformed_multipart":
      case "missing_metadata":
      case "invalid_metadata":
      case "invalid_metadata_json":
      case "missing_blob":
      case "invalid_blob":
      case "invalid_blob_b64":
      case "metadata_mismatch":
      case "invalid_capture_id":
        return RevclustOwnedUploadRejected(
          code: RevclustRejectionCode.invalidRequest,
          errorCode: RevclustUploadErrorCode.invalidRequest,
          message: message,
          statusCode: statusCode,
        );
      case "storage_write_failed":
      case "pack_metadata_write_failed":
      case "internal_error":
        return RevclustOwnedUploadRejected(
          code: RevclustRejectionCode.internalError,
          errorCode: RevclustUploadErrorCode.internalError,
          message: message,
          statusCode: statusCode,
        );
      default:
        return null;
    }
  }

  static Uri? _buildViewerUrl({
    required Uri? viewerBaseUrl,
    required String packId,
  }) {
    if (viewerBaseUrl == null) {
      return null;
    }
    final String basePath = viewerBaseUrl.path.endsWith("/")
        ? viewerBaseUrl.path
        : "${viewerBaseUrl.path}/";
    return viewerBaseUrl.replace(path: "$basePath$packId");
  }

  static bool _isRetryableStatus(int? statusCode) {
    if (statusCode == null) {
      return true;
    }
    return statusCode == 408 ||
        statusCode == 429 ||
        statusCode == 502 ||
        statusCode == 503 ||
        statusCode == 504;
  }

  static Map<String, Object?> _asObjectMap(dynamic value) {
    return _asObjectMapOrNull(value) ?? const <String, Object?>{};
  }

  static Map<String, Object?>? _asObjectMapOrNull(dynamic value) {
    if (value is Map<String, Object?>) {
      return Map<String, Object?>.from(value);
    }
    if (value is Map<Object?, Object?>) {
      return Map<String, Object?>.from(value);
    }
    return null;
  }

  static String? _readOptionalString(Map<String, Object?> value, String key) {
    final Object? entry = value[key];
    if (entry is String && entry.trim().isNotEmpty) {
      return entry.trim();
    }
    return null;
  }

  static int? _readOptionalInt(Object? value) {
    return value is int && value >= 0 ? value : null;
  }
}

sealed class RevclustDrainAccess {
  const RevclustDrainAccess();
}

final class RevclustDrainAccessReady extends RevclustDrainAccess {
  const RevclustDrainAccessReady(this.lease);

  final RevclustBootstrapLease lease;
}

final class RevclustDrainAccessUnavailable extends RevclustDrainAccess {
  const RevclustDrainAccessUnavailable({
    required this.errorCode,
    required this.retryable,
    this.message,
  });

  final RevclustUploadErrorCode errorCode;
  final bool retryable;
  final String? message;
}

abstract interface class RevclustDrainBootstrapDelegate {
  Future<RevclustDrainAccess> ensureReadyForDrain();

  Future<RevclustDrainAccess> refreshAfterAuthFailure();
}

/// Single-flight drain coordinator used behind the public facade runtime.
final class RevclustOwnedUploadCoordinator {
  RevclustOwnedUploadCoordinator({
    required LocalPackRepository repository,
    required RevclustDrainBootstrapDelegate bootstrapDelegate,
    required RevclustOwnedUploadTransport transport,
    required RevclustOwnedUploadRetryPolicy retryPolicy,
    required DateTime Function() utcNow,
    required Future<void> Function() onQueueStateChanged,
    required void Function(RevclustUploadErrorCode? errorCode) onLastError,
    required void Function(RevclustUploadEvent event) onEvent,
  })  : _repository = repository,
        _bootstrapDelegate = bootstrapDelegate,
        _transport = transport,
        _retryPolicy = retryPolicy,
        _utcNow = utcNow,
        _onQueueStateChanged = onQueueStateChanged,
        _onLastError = onLastError,
        _onEvent = onEvent;

  final LocalPackRepository _repository;
  final RevclustDrainBootstrapDelegate _bootstrapDelegate;
  final RevclustOwnedUploadTransport _transport;
  final RevclustOwnedUploadRetryPolicy _retryPolicy;
  final DateTime Function() _utcNow;
  final Future<void> Function() _onQueueStateChanged;
  final void Function(RevclustUploadErrorCode? errorCode) _onLastError;
  final void Function(RevclustUploadEvent event) _onEvent;

  Timer? _wakeTimer;
  Future<void>? _drainFuture;
  bool _drainRequested = false;
  bool _drainStartScheduled = false;
  bool _isDisposed = false;

  void requestDrain() {
    if (_isDisposed) {
      return;
    }
    _wakeTimer?.cancel();
    _wakeTimer = null;
    _drainRequested = true;
    if (_drainFuture != null || _drainStartScheduled) {
      return;
    }
    _drainStartScheduled = true;
    scheduleMicrotask(() {
      _drainStartScheduled = false;
      if (_isDisposed || _drainFuture != null || !_drainRequested) {
        return;
      }
      _drainRequested = false;
      _drainFuture = _runDrainLoop().whenComplete(() {
        _drainFuture = null;
        if (_isDisposed || !_drainRequested) {
          return;
        }
        requestDrain();
      });
    });
  }

  void dispose() {
    _isDisposed = true;
    _wakeTimer?.cancel();
    _wakeTimer = null;
  }

  Future<void> _runDrainLoop() async {
    try {
      await _repository.requeueExpiredClaims(
        claimLeaseMs: _retryPolicy.claimLease.inMilliseconds,
      );
      await _onQueueStateChanged();

      while (!_isDisposed) {
        final RevclustDrainAccess access =
            await _bootstrapDelegate.ensureReadyForDrain();
        if (access is RevclustDrainAccessUnavailable) {
          _onLastError(access.errorCode);
          await _onQueueStateChanged();
          await _scheduleBlockedWake(retryable: access.retryable);
          return;
        }

        final LocalPackRecord? claimed =
            await _repository.claimNextUploadable();
        if (claimed == null) {
          await _scheduleReadyWake();
          return;
        }

        await _onQueueStateChanged();
        _onEvent(RevclustUploadStarted(captureId: claimed.captureId));
        await _processClaimed(
          claimed,
          (access as RevclustDrainAccessReady).lease,
        );
      }
    } on Object catch (_) {
      if (_isDisposed) {
        return;
      }
      await _containUnexpectedFailure();
    }
  }

  Future<void> _processClaimed(
    LocalPackRecord claimed,
    RevclustBootstrapLease lease,
  ) async {
    int attemptsUsed = 1;
    RevclustOwnedUploadTransportResult result = await _transport.upload(
      claimedPack: claimed,
      lease: lease,
    );

    if (result is RevclustOwnedUploadRejected &&
        result.code == RevclustRejectionCode.auth) {
      final RevclustDrainAccess refreshed =
          await _bootstrapDelegate.refreshAfterAuthFailure();
      if (refreshed is RevclustDrainAccessReady) {
        attemptsUsed += 1;
        result = await _transport.upload(
          claimedPack: claimed,
          lease: refreshed.lease,
        );
      } else {
        await _handleTransportFailure(
          claimed,
          RevclustOwnedUploadTransportFailure(
            errorCode: (refreshed as RevclustDrainAccessUnavailable).errorCode,
            retryable: refreshed.retryable,
            message: refreshed.message ??
                "Upload authorization expired and could not be refreshed.",
            statusCode: result.statusCode,
          ),
          attemptsUsed: attemptsUsed,
        );
        return;
      }
    }

    switch (result) {
      case RevclustOwnedUploadAccepted():
        await _repository.markUploaded(
          claimed.captureId,
          attemptsUsed: attemptsUsed,
        );
        _onLastError(null);
        await _onQueueStateChanged();
        _onEvent(
          RevclustUploadAccepted(
            captureId: claimed.captureId,
            result: result.result,
          ),
        );
        return;
      case RevclustOwnedUploadRejected():
        await _repository.markFailed(
          claimed.captureId,
          lastErrorCode: result.errorCode.name,
          attemptsUsed: attemptsUsed,
        );
        _onLastError(result.errorCode);
        await _onQueueStateChanged();
        _onEvent(
          RevclustUploadRejected(
            captureId: claimed.captureId,
            code: result.code,
            message: result.message,
          ),
        );
        return;
      case RevclustOwnedUploadTransportFailure():
        await _handleTransportFailure(
          claimed,
          result,
          attemptsUsed: attemptsUsed,
        );
        return;
    }
  }

  Future<void> _handleTransportFailure(
    LocalPackRecord claimed,
    RevclustOwnedUploadTransportFailure result, {
    required int attemptsUsed,
  }) async {
    final int completedAttemptCount = claimed.attemptCount + attemptsUsed;
    final bool attemptsRemaining =
        completedAttemptCount < _retryPolicy.maxAttempts;
    if (result.retryable && attemptsRemaining) {
      final DateTime nextAttemptAt = _utcNow().add(
        _retryPolicy.backoffForAttempt(completedAttemptCount),
      );
      await _repository.releaseClaimForRetry(
        claimed.captureId,
        nextAttemptAtUtcMs: nextAttemptAt.millisecondsSinceEpoch,
        lastErrorCode: result.errorCode.name,
        attemptsUsed: attemptsUsed,
      );
      _onLastError(result.errorCode);
      await _onQueueStateChanged();
      _onEvent(
        RevclustTransportFailure(
          captureId: claimed.captureId,
          statusCode: result.statusCode,
          message: result.message,
          retryable: true,
        ),
      );
      return;
    }

    await _repository.markFailed(
      claimed.captureId,
      lastErrorCode: result.errorCode.name,
      attemptsUsed: attemptsUsed,
    );
    _onLastError(result.errorCode);
    await _onQueueStateChanged();
    _onEvent(
      RevclustTransportFailure(
        captureId: claimed.captureId,
        statusCode: result.statusCode,
        message: result.message,
        retryable: false,
      ),
    );
  }

  Future<void> _scheduleReadyWake() async {
    final int? nextAttemptAtUtcMs = await _repository.nextPendingAttemptAt();
    final int? nextClaimExpiryAtUtcMs = await _repository.nextClaimExpiryAt(
      claimLeaseMs: _retryPolicy.claimLease.inMilliseconds,
    );
    final int? nextWakeAtUtcMs = _earliestUtcMs(
      nextAttemptAtUtcMs,
      nextClaimExpiryAtUtcMs,
    );
    if (_isDisposed || nextWakeAtUtcMs == null) {
      return;
    }
    _scheduleWakeAt(nextWakeAtUtcMs);
  }

  Future<void> _scheduleBlockedWake({
    required bool retryable,
  }) async {
    final int nowUtcMs = _utcNow().millisecondsSinceEpoch;
    final int? nextPendingAttemptAtUtcMs =
        retryable ? await _repository.nextPendingAttemptAt() : null;
    final int? nextClaimExpiryAtUtcMs = await _repository.nextClaimExpiryAt(
      claimLeaseMs: _retryPolicy.claimLease.inMilliseconds,
    );
    final bool hasQueuedWork =
        nextPendingAttemptAtUtcMs != null || nextClaimExpiryAtUtcMs != null;
    final int? blockedWakeAtUtcMs = retryable && hasQueuedWork
        ? nowUtcMs + _retryPolicy.blockedPollInterval.inMilliseconds
        : null;
    final int? nextWakeAtUtcMs = _earliestUtcMs(
      blockedWakeAtUtcMs,
      nextClaimExpiryAtUtcMs,
    );
    if (nextWakeAtUtcMs == null) {
      return;
    }
    _scheduleWakeAt(nextWakeAtUtcMs);
  }

  Future<void> _containUnexpectedFailure() async {
    _onLastError(RevclustUploadErrorCode.internalError);
    try {
      await _onQueueStateChanged();
    } on Object {
      // Keep the last known counts visible when the queue cannot be refreshed.
    }
    try {
      await _scheduleReadyWake();
    } on Object {
      _scheduleWake(_retryPolicy.claimLease);
    }
  }

  int? _earliestUtcMs(int? first, int? second) {
    if (first == null) {
      return second;
    }
    if (second == null) {
      return first;
    }
    return first <= second ? first : second;
  }

  void _scheduleWakeAt(int wakeAtUtcMs) {
    final int nowUtcMs = _utcNow().millisecondsSinceEpoch;
    final Duration delay = wakeAtUtcMs <= nowUtcMs
        ? Duration.zero
        : Duration(milliseconds: wakeAtUtcMs - nowUtcMs);
    _scheduleWake(delay);
  }

  void _scheduleWake(Duration delay) {
    if (_isDisposed) {
      return;
    }
    _wakeTimer?.cancel();
    _wakeTimer = Timer(delay, requestDrain);
  }
}
