import "package:dio/dio.dart";

import "_validation.dart";
import "revclust_config.dart";

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
  });

  RevclustBootstrapAssessment.ready({
    required RevclustBootstrapLease lease,
    String? message,
  }) : this._(
          RevclustBootstrapDisposition.ready,
          message: message,
          lease: lease,
        );

  const RevclustBootstrapAssessment.bootstrapUnavailable({
    String? message,
  }) : this._(
          RevclustBootstrapDisposition.bootstrapUnavailable,
          message: message,
        );

  const RevclustBootstrapAssessment.misconfigured({
    String? message,
  }) : this._(
          RevclustBootstrapDisposition.misconfigured,
          message: message,
        );

  const RevclustBootstrapAssessment.notProvisioned({
    String? message,
  }) : this._(
          RevclustBootstrapDisposition.notProvisioned,
          message: message,
        );

  const RevclustBootstrapAssessment.uploadBlocked({
    String? message,
  }) : this._(
          RevclustBootstrapDisposition.uploadBlocked,
          message: message,
        );

  final RevclustBootstrapDisposition disposition;
  final String? message;
  final RevclustBootstrapLease? lease;
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
    final Uri endpoint = _defaultBootstrapEndpoint(config.environment);
    Response<dynamic> response;
    try {
      response = await _dio.postUri(
        endpoint,
        data: <String, Object?>{
          "project_key": config.projectKey,
          "environment": config.environment.name,
        },
        options: Options(
          headers: <String, Object?>{
            Headers.acceptHeader: Headers.jsonContentType,
          },
          contentType: Headers.jsonContentType,
        ),
      );
    } on DioException catch (error) {
      return RevclustBootstrapAssessment.bootstrapUnavailable(
        message: _describeTransportFailure(error),
      );
    }

    final Map<String, Object?> body = _asObjectMap(response.data);
    final _ParsedBootstrapError? parsedError = _parseBootstrapError(body);
    if (response.statusCode == 200 || response.statusCode == 201) {
      final RevclustBootstrapAssessment? success = _parseSuccessBody(
        body,
        parsedError: parsedError,
      );
      if (success != null) {
        return success;
      }
    }

    return _mapFailure(
      statusCode: response.statusCode,
      parsedError: parsedError,
    );
  }

  RevclustBootstrapAssessment? _parseSuccessBody(
    Map<String, Object?> body, {
    required _ParsedBootstrapError? parsedError,
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
        message: parsedError?.message ??
            "Hosted bootstrap returned expired upload authorization.",
      );
    }
    return RevclustBootstrapAssessment.ready(
      lease: lease,
      message: parsedError?.message,
    );
  }

  RevclustBootstrapAssessment _mapFailure({
    required int? statusCode,
    required _ParsedBootstrapError? parsedError,
  }) {
    final String? code = parsedError?.code;
    final String? message = parsedError?.message;
    switch (code) {
      case "misconfigured":
      case "invalid_project_key":
      case "project_key_invalid":
      case "invalid_project":
        return RevclustBootstrapAssessment.misconfigured(
          message: message ??
              "Project key is misconfigured for the selected environment.",
        );
      case "not_provisioned":
      case "project_not_provisioned":
      case "project_unavailable":
        return RevclustBootstrapAssessment.notProvisioned(
          message: message ??
              "Project key is not provisioned for the selected environment.",
        );
      case "upload_blocked":
      case "upload_auth_unavailable":
      case "auth_expired":
      case "auth_unavailable":
        return RevclustBootstrapAssessment.uploadBlocked(
          message: message ??
              "Upload authorization could not be obtained right now.",
        );
      default:
        if (statusCode == 400) {
          return RevclustBootstrapAssessment.misconfigured(
            message:
                message ?? "Hosted bootstrap rejected the project key request.",
          );
        }
        if (statusCode == 401 || statusCode == 403) {
          return RevclustBootstrapAssessment.uploadBlocked(
            message:
                message ?? "Hosted bootstrap rejected upload authorization.",
          );
        }
        if (statusCode == 404) {
          return RevclustBootstrapAssessment.notProvisioned(
            message: message ??
                "Project key is not provisioned for the selected environment.",
          );
        }
        return RevclustBootstrapAssessment.bootstrapUnavailable(
          message: message ??
              "Hosted bootstrap could not be completed successfully.",
        );
    }
  }

  static Uri _defaultBootstrapEndpoint(RevclustEnvironment environment) {
    final String origin = switch (environment) {
      RevclustEnvironment.production => "https://revclust.com",
      RevclustEnvironment.staging => "https://staging.revclust.com",
      RevclustEnvironment.development => "http://127.0.0.1:3000",
    };
    return Uri.parse("$origin/api/pilot/sdk/bootstrap");
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
      code: _readOptionalString(error, <String>["code"]),
      message: _readOptionalString(error, <String>["message"]),
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
    final String? message = error.message?.trim();
    if (message != null && message.isNotEmpty) {
      return message;
    }
    return "Hosted bootstrap could not be reached.";
  }
}

final class _ParsedBootstrapError {
  const _ParsedBootstrapError({
    required this.code,
    required this.message,
  });

  final String? code;
  final String? message;
}

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
