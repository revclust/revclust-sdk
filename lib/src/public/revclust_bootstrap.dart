import "package:dio/dio.dart";

import "_validation.dart";
import "revclust_bootstrap_origin.dart";
import "revclust_config.dart";
import "revclust_diagnostics.dart";

/// Short-lived upload authorization returned by hosted bootstrap.
final class RevclustBootstrapLease {
  RevclustBootstrapLease({
    required Uri uploadEndpoint,
    required String authToken,
    required DateTime usableUntil,
    Uri? viewerBaseUrl,
  })  : uploadEndpoint = _normalizeHttpsOrHttpUri(
          uploadEndpoint,
          "uploadEndpoint",
        ),
        authToken = normalizeRequiredString(authToken, "authToken"),
        usableUntil = usableUntil.toUtc(),
        viewerBaseUrl = viewerBaseUrl == null
            ? null
            : _normalizeHttpsOrHttpUri(
                viewerBaseUrl,
                "viewerBaseUrl",
              );

  final Uri uploadEndpoint;
  final String authToken;
  final DateTime usableUntil;
  final Uri? viewerBaseUrl;

  bool isUsableAt(DateTime utcNow) => usableUntil.isAfter(utcNow.toUtc());
}

/// Result of the hosted bootstrap exchange used by the public facade.
final class RevclustBootstrapAssessment {
  const RevclustBootstrapAssessment._(
    this.disposition, {
    this.message,
    this.lease,
    this.diagnostics,
  });

  RevclustBootstrapAssessment.ready({
    required RevclustBootstrapLease lease,
    String? message,
    RevclustBootstrapDiagnostics? diagnostics,
  }) : this._(
          RevclustBootstrapDisposition.ready,
          message: message,
          lease: lease,
          diagnostics: diagnostics,
        );

  const RevclustBootstrapAssessment.bootstrapUnavailable({
    String? message,
    RevclustBootstrapDiagnostics? diagnostics,
  }) : this._(
          RevclustBootstrapDisposition.bootstrapUnavailable,
          message: message,
          diagnostics: diagnostics,
        );

  const RevclustBootstrapAssessment.misconfigured({
    String? message,
    RevclustBootstrapDiagnostics? diagnostics,
  }) : this._(
          RevclustBootstrapDisposition.misconfigured,
          message: message,
          diagnostics: diagnostics,
        );

  const RevclustBootstrapAssessment.notProvisioned({
    String? message,
    RevclustBootstrapDiagnostics? diagnostics,
  }) : this._(
          RevclustBootstrapDisposition.notProvisioned,
          message: message,
          diagnostics: diagnostics,
        );

  const RevclustBootstrapAssessment.uploadBlocked({
    String? message,
    RevclustBootstrapDiagnostics? diagnostics,
  }) : this._(
          RevclustBootstrapDisposition.uploadBlocked,
          message: message,
          diagnostics: diagnostics,
        );

  final RevclustBootstrapDisposition disposition;
  final String? message;
  final RevclustBootstrapLease? lease;
  final RevclustBootstrapDiagnostics? diagnostics;
}

/// Bootstrap outcomes available to the public facade runtime.
enum RevclustBootstrapDisposition {
  ready,
  bootstrapUnavailable,
  misconfigured,
  notProvisioned,
  uploadBlocked,
}

/// Internal bootstrap contract used by the hosted public facade runtime.
abstract interface class RevclustBootstrapProbe {
  Future<RevclustBootstrapAssessment> assess(RevclustConfig config);
}

/// Default hosted bootstrap client used outside deterministic tests.
final class HttpRevclustBootstrapProbe implements RevclustBootstrapProbe {
  HttpRevclustBootstrapProbe({
    Dio? dio,
    DateTime Function()? utcNow,
  })  : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 3),
                sendTimeout: const Duration(seconds: 3),
                receiveTimeout: const Duration(seconds: 3),
                responseType: ResponseType.json,
                validateStatus: (_) => true,
              ),
            ),
        _utcNow = utcNow ?? (() => DateTime.now().toUtc());

  final Dio _dio;
  final DateTime Function() _utcNow;

  @override
  Future<RevclustBootstrapAssessment> assess(RevclustConfig config) async {
    final Uri bootstrapOrigin = _bootstrapOrigin(config);
    final Uri endpoint = _bootstrapEndpoint(bootstrapOrigin);
    final DateTime checkedAt = _utcNow();
    Response<dynamic> response;
    try {
      response = await _dio.postUri(
        endpoint,
        data: <String, Object?>{
          "project_key": config.projectKey,
        },
        options: Options(
          headers: <String, Object?>{
            Headers.acceptHeader: Headers.jsonContentType,
          },
          contentType: Headers.jsonContentType,
        ),
      );
    } on DioException catch (error) {
      final String message = _describeTransportFailure(error);
      return RevclustBootstrapAssessment.bootstrapUnavailable(
        message: message,
        diagnostics: _diagnostics(
          state: RevclustBootstrapDiagnosticState.unavailable,
          bootstrapOrigin: bootstrapOrigin,
          checkedAt: checkedAt,
          statusCode: error.response?.statusCode,
          errorCategory: "transport_unavailable",
          retryable: _isRetryableStatus(error.response?.statusCode) ||
              error.response == null,
          message: message,
        ),
      );
    }

    final Map<String, Object?> body = _asObjectMap(response.data);
    final _ParsedBootstrapError? parsedError = _parseBootstrapError(body);
    if (response.statusCode == 200 || response.statusCode == 201) {
      final RevclustBootstrapAssessment? success = _parseSuccessBody(
        body,
        bootstrapOrigin: bootstrapOrigin,
        checkedAt: checkedAt,
        statusCode: response.statusCode,
      );
      if (success != null) {
        return success;
      }
    }

    return _mapFailure(
      statusCode: response.statusCode,
      parsedError: parsedError,
      bootstrapOrigin: bootstrapOrigin,
      checkedAt: checkedAt,
    );
  }

  RevclustBootstrapAssessment? _parseSuccessBody(
    Map<String, Object?> body, {
    required Uri bootstrapOrigin,
    required DateTime checkedAt,
    required int? statusCode,
  }) {
    final Map<String, Object?>? upload =
        _asObjectMapOrNull(body["upload"]) ?? _asObjectMapOrNull(body);
    if (upload == null) {
      return null;
    }

    final String? endpoint = _readOptionalString(
      upload,
      <String>["endpoint", "upload_endpoint"],
    );
    final String? authToken = _readOptionalString(
      upload,
      <String>["auth_token", "token", "upload_auth_token"],
    );
    final String? usableUntilRaw = _readOptionalString(
      upload,
      <String>["usable_until", "expires_at", "auth_expires_at"],
    );
    if (endpoint == null || authToken == null || usableUntilRaw == null) {
      return null;
    }

    final DateTime? usableUntil = DateTime.tryParse(usableUntilRaw)?.toUtc();
    if (usableUntil == null) {
      return null;
    }

    final Uri? viewerBaseUrl = _parseViewerBaseUrl(body);
    final RevclustBootstrapLease lease = RevclustBootstrapLease(
      uploadEndpoint: Uri.parse(endpoint),
      authToken: authToken,
      usableUntil: usableUntil,
      viewerBaseUrl: viewerBaseUrl,
    );
    if (!lease.isUsableAt(_utcNow())) {
      return RevclustBootstrapAssessment.uploadBlocked(
        message: "Hosted bootstrap returned expired upload authorization.",
        diagnostics: _diagnostics(
          state: RevclustBootstrapDiagnosticState.uploadBlocked,
          bootstrapOrigin: bootstrapOrigin,
          checkedAt: checkedAt,
          statusCode: statusCode,
          errorCategory: "auth_expired",
          retryable: true,
          message: "Hosted bootstrap returned expired upload authorization.",
        ),
      );
    }
    return RevclustBootstrapAssessment.ready(
      lease: lease,
      diagnostics: _diagnostics(
        state: RevclustBootstrapDiagnosticState.ready,
        bootstrapOrigin: bootstrapOrigin,
        checkedAt: checkedAt,
        statusCode: statusCode,
        retryable: false,
      ),
    );
  }

  RevclustBootstrapAssessment _mapFailure({
    required int? statusCode,
    required _ParsedBootstrapError? parsedError,
    required Uri bootstrapOrigin,
    required DateTime checkedAt,
  }) {
    final String? code = parsedError?.code;
    switch (code) {
      case "misconfigured":
      case "invalid_project_key":
      case "project_key_invalid":
      case "invalid_project":
        final String message = _failureMessageFor(
          code: code,
          statusCode: statusCode,
        );
        return RevclustBootstrapAssessment.misconfigured(
          message: message,
          diagnostics: _diagnostics(
            state: RevclustBootstrapDiagnosticState.misconfigured,
            bootstrapOrigin: bootstrapOrigin,
            checkedAt: checkedAt,
            statusCode: statusCode,
            errorCategory: code,
            retryable: false,
            message: message,
          ),
        );
      case "not_provisioned":
      case "project_not_provisioned":
      case "project_unavailable":
        final String message = _failureMessageFor(
          code: code,
          statusCode: statusCode,
        );
        return RevclustBootstrapAssessment.notProvisioned(
          message: message,
          diagnostics: _diagnostics(
            state: RevclustBootstrapDiagnosticState.notProvisioned,
            bootstrapOrigin: bootstrapOrigin,
            checkedAt: checkedAt,
            statusCode: statusCode,
            errorCategory: code,
            retryable: false,
            message: message,
          ),
        );
      case "upload_blocked":
      case "upload_auth_unavailable":
      case "auth_expired":
      case "auth_unavailable":
        final String message = _failureMessageFor(
          code: code,
          statusCode: statusCode,
        );
        return RevclustBootstrapAssessment.uploadBlocked(
          message: message,
          diagnostics: _diagnostics(
            state: RevclustBootstrapDiagnosticState.uploadBlocked,
            bootstrapOrigin: bootstrapOrigin,
            checkedAt: checkedAt,
            statusCode: statusCode,
            errorCategory: code,
            retryable: true,
            message: message,
          ),
        );
      default:
        if (statusCode == 400) {
          final String message = _failureMessageFor(
            code: code,
            statusCode: statusCode,
          );
          return RevclustBootstrapAssessment.misconfigured(
            message: message,
            diagnostics: _diagnostics(
              state: RevclustBootstrapDiagnosticState.misconfigured,
              bootstrapOrigin: bootstrapOrigin,
              checkedAt: checkedAt,
              statusCode: statusCode,
              errorCategory: code ?? "invalid_project_key",
              retryable: false,
              message: message,
            ),
          );
        }
        if (statusCode == 401 || statusCode == 403) {
          final String message = _failureMessageFor(
            code: code,
            statusCode: statusCode,
          );
          return RevclustBootstrapAssessment.uploadBlocked(
            message: message,
            diagnostics: _diagnostics(
              state: RevclustBootstrapDiagnosticState.uploadBlocked,
              bootstrapOrigin: bootstrapOrigin,
              checkedAt: checkedAt,
              statusCode: statusCode,
              errorCategory: code ?? "upload_auth_unavailable",
              retryable: true,
              message: message,
            ),
          );
        }
        if (statusCode == 404) {
          final String message = _failureMessageFor(
            code: code,
            statusCode: statusCode,
          );
          return RevclustBootstrapAssessment.notProvisioned(
            message: message,
            diagnostics: _diagnostics(
              state: RevclustBootstrapDiagnosticState.notProvisioned,
              bootstrapOrigin: bootstrapOrigin,
              checkedAt: checkedAt,
              statusCode: statusCode,
              errorCategory: code ?? "project_not_provisioned",
              retryable: false,
              message: message,
            ),
          );
        }
        final String message = _failureMessageFor(
          code: code,
          statusCode: statusCode,
        );
        return RevclustBootstrapAssessment.bootstrapUnavailable(
          message: message,
          diagnostics: _diagnostics(
            state: RevclustBootstrapDiagnosticState.unavailable,
            bootstrapOrigin: bootstrapOrigin,
            checkedAt: checkedAt,
            statusCode: statusCode,
            errorCategory: code ?? "bootstrap_unavailable",
            retryable: _isRetryableStatus(statusCode),
            message: message,
          ),
        );
    }
  }

  static Uri _bootstrapOrigin(RevclustConfig config) {
    return resolveInternalRevclustBootstrapOrigin(config);
  }

  static Uri _bootstrapEndpoint(Uri origin) {
    return origin.resolve("/api/pilot/sdk/bootstrap");
  }

  static RevclustBootstrapDiagnostics _diagnostics({
    required RevclustBootstrapDiagnosticState state,
    required Uri bootstrapOrigin,
    required DateTime checkedAt,
    int? statusCode,
    String? errorCategory,
    bool? retryable,
    String? message,
  }) {
    return RevclustBootstrapDiagnostics(
      state: state,
      bootstrapOrigin: bootstrapOrigin,
      lastCheckedAt: checkedAt.toUtc(),
      lastHttpStatus: statusCode,
      errorCategory: errorCategory,
      retryable: retryable,
      message: message,
    );
  }

  static bool _isRetryableStatus(int? statusCode) {
    return statusCode == null ||
        statusCode == 408 ||
        statusCode == 429 ||
        statusCode >= 500;
  }

  static Uri? _parseViewerBaseUrl(Map<String, Object?> body) {
    final String? direct = _readOptionalString(
      body,
      <String>["viewer_base_url"],
    );
    if (direct != null) {
      return Uri.parse(direct);
    }
    final Map<String, Object?>? viewer = _asObjectMapOrNull(body["viewer"]);
    final String? nested = viewer == null
        ? null
        : _readOptionalString(
            viewer,
            <String>["base_url", "viewer_base_url"],
          );
    return nested == null ? null : Uri.parse(nested);
  }

  static _ParsedBootstrapError? _parseBootstrapError(
      Map<String, Object?> body) {
    final Map<String, Object?>? error = _asObjectMapOrNull(body["error"]);
    if (error == null) {
      return null;
    }
    return _ParsedBootstrapError(
      code: _readKnownErrorCode(_readOptionalString(error, <String>["code"])),
    );
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

  static String? _readOptionalString(
    Map<String, Object?> value,
    List<String> keys,
  ) {
    for (final String key in keys) {
      final Object? entry = value[key];
      if (entry is String && entry.trim().isNotEmpty) {
        return entry.trim();
      }
    }
    return null;
  }

  static String _describeTransportFailure(DioException error) {
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout =>
        "Hosted bootstrap timed out.",
      DioExceptionType.badCertificate =>
        "Hosted bootstrap TLS verification failed.",
      _ => "Hosted bootstrap could not be reached.",
    };
  }

  static String? _readKnownErrorCode(String? value) {
    final String? normalized = value?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    return _knownBootstrapErrorCodes.contains(normalized) ? normalized : null;
  }

  static String _failureMessageFor({
    required String? code,
    required int? statusCode,
  }) {
    switch (code) {
      case "misconfigured":
      case "invalid_project_key":
      case "project_key_invalid":
      case "invalid_project":
        return "Project key is misconfigured.";
      case "not_provisioned":
      case "project_not_provisioned":
      case "project_unavailable":
        return "Project key is not provisioned.";
      case "upload_blocked":
      case "upload_auth_unavailable":
      case "auth_expired":
      case "auth_unavailable":
        return "Upload authorization could not be obtained right now.";
    }
    if (statusCode == 400) {
      return "Hosted bootstrap rejected the project key request.";
    }
    if (statusCode == 401 || statusCode == 403) {
      return "Hosted bootstrap rejected upload authorization.";
    }
    if (statusCode == 404) {
      return "Project key is not provisioned.";
    }
    return "Hosted bootstrap could not be completed successfully.";
  }
}

final class _ParsedBootstrapError {
  const _ParsedBootstrapError({
    required this.code,
  });

  final String? code;
}

const Set<String> _knownBootstrapErrorCodes = <String>{
  "misconfigured",
  "invalid_project_key",
  "project_key_invalid",
  "invalid_project",
  "not_provisioned",
  "project_not_provisioned",
  "project_unavailable",
  "upload_blocked",
  "upload_auth_unavailable",
  "auth_expired",
  "auth_unavailable",
  "bootstrap_unavailable",
};

Uri _normalizeHttpsOrHttpUri(Uri value, String name) {
  if (!value.hasScheme || (value.scheme != "https" && value.scheme != "http")) {
    throw ArgumentError.value(
      value,
      name,
      "must be an absolute http or https URI",
    );
  }
  return value;
}
