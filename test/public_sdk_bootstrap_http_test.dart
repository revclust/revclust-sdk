import "dart:async";
import "dart:convert";
import "dart:typed_data";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter/src/public/revclust_bootstrap.dart";
import "package:revclust_flutter/src/public/revclust_config.dart";
import "package:revclust_flutter/src/public/revclust_diagnostics.dart";

// Deliberately synthetic shape-valid test keys; never use these outside tests.
const String _validSdkKey = "rpk_00000000000000000000000000000000";
const String _missingSdkKey = "rpk_11111111111111111111111111111111";

void main() {
  test("default config posts key-only body to canonical bootstrap endpoint",
      () async {
    final _RecordingBootstrapAdapter adapter = _RecordingBootstrapAdapter(
      statusCode: 200,
      responseBody: _successBody(
        endpoint: "https://revclust.com/api/incident-packs",
        viewerBaseUrl: "https://revclust.com/app/incidents",
      ),
    );
    final HttpRevclustBootstrapProbe probe = _probeWithAdapter(
      adapter,
      utcNow: () => DateTime.parse("2026-03-28T12:00:00.000Z"),
    );

    final RevclustBootstrapAssessment assessment = await probe.assess(
      RevclustConfig(
        projectKey: _validSdkKey,
        releaseStage: RevclustAppReleaseStage.production,
        appVersion: "1.2.3",
        build: "1203",
        gitSha: "ABCDEF1",
      ),
    );

    expect(assessment.disposition, RevclustBootstrapDisposition.ready);
    expect(
      adapter.lastRequestUri,
      "https://revclust.com/api/sdk/bootstrap",
    );
    expect(adapter.lastRequestMethod, "POST");
    expect(
      jsonDecode(adapter.lastRequestBody ?? "") as Map<String, Object?>,
      <String, Object?>{
        "project_key": _validSdkKey,
      },
    );
    expect(
      assessment.diagnostics?.bootstrapOrigin,
      Uri.parse("https://revclust.com"),
    );
    expect(
      assessment.diagnostics?.state,
      RevclustBootstrapDiagnosticState.ready,
    );
  });

  test("404 project_not_provisioned maps to notProvisioned diagnostics",
      () async {
    final HttpRevclustBootstrapProbe probe = _probeWithResponse(
      statusCode: 404,
      responseBody: jsonEncode(<String, Object?>{
        "ok": false,
        "error": <String, Object?>{
          "code": "project_not_provisioned",
          "message": "SDK key is not available.",
        },
      }),
    );

    final RevclustBootstrapAssessment assessment = await probe.assess(
      RevclustConfig(projectKey: _missingSdkKey),
    );

    expect(
      assessment.disposition,
      RevclustBootstrapDisposition.notProvisioned,
    );
    expect(assessment.message, "SDK key is not available.");
    expect(
      assessment.diagnostics?.state,
      RevclustBootstrapDiagnosticState.notProvisioned,
    );
    expect(assessment.diagnostics?.lastHttpStatus, 404);
    expect(assessment.diagnostics?.errorCategory, "project_not_provisioned");
    expect(assessment.diagnostics?.retryable, isFalse);
  });

  test("403 upload_auth_unavailable maps to uploadBlocked diagnostics",
      () async {
    final HttpRevclustBootstrapProbe probe = _probeWithResponse(
      statusCode: 403,
      responseBody: jsonEncode(<String, Object?>{
        "ok": false,
        "error": <String, Object?>{
          "code": "upload_auth_unavailable",
          "message":
              "Do not expose sensitive_key_marker or sensitive_upload_marker.",
        },
      }),
    );

    final RevclustBootstrapAssessment assessment = await probe.assess(
      RevclustConfig(projectKey: _validSdkKey),
    );

    expect(
      assessment.disposition,
      RevclustBootstrapDisposition.uploadBlocked,
    );
    expect(
      assessment.message,
      "Upload authorization could not be obtained right now.",
    );
    expect(
      assessment.diagnostics?.state,
      RevclustBootstrapDiagnosticState.uploadBlocked,
    );
    expect(assessment.diagnostics?.lastHttpStatus, 403);
    expect(assessment.diagnostics?.errorCategory, "upload_auth_unavailable");
    expect(assessment.diagnostics?.retryable, isTrue);
    expect(
      assessment.diagnostics?.message,
      "Upload authorization could not be obtained right now.",
    );
    expect(
      assessment.diagnostics?.message,
      isNot(contains("sensitive_key")),
    );
    expect(
      assessment.diagnostics?.message,
      isNot(contains("sensitive_upload")),
    );
  });

  test("400 invalid_project_key maps to misconfigured diagnostics", () async {
    final HttpRevclustBootstrapProbe probe = _probeWithResponse(
      statusCode: 400,
      responseBody: jsonEncode(<String, Object?>{
        "ok": false,
        "error": <String, Object?>{
          "code": "invalid_project_key",
          "message": "Do not expose sensitive_key_marker.",
        },
      }),
    );

    final RevclustBootstrapAssessment assessment = await probe.assess(
      RevclustConfig(projectKey: _validSdkKey),
    );

    expect(
      assessment.disposition,
      RevclustBootstrapDisposition.misconfigured,
    );
    expect(
      assessment.message,
      "SDK key is misconfigured.",
    );
    expect(
      assessment.diagnostics?.state,
      RevclustBootstrapDiagnosticState.misconfigured,
    );
    expect(assessment.diagnostics?.lastHttpStatus, 400);
    expect(assessment.diagnostics?.errorCategory, "invalid_project_key");
    expect(assessment.diagnostics?.retryable, isFalse);
    expect(assessment.diagnostics?.message, "SDK key is misconfigured.");
    expect(
      assessment.diagnostics?.message,
      isNot(contains("sensitive_key")),
    );
  });

  test("unknown bootstrap error bodies do not leak messages or categories",
      () async {
    final HttpRevclustBootstrapProbe probe = _probeWithResponse(
      statusCode: 503,
      responseBody: jsonEncode(<String, Object?>{
        "ok": false,
        "error": <String, Object?>{
          "code": "sensitive_key_code",
          "message": "raw request body included sensitive_key_marker",
        },
      }),
    );

    final RevclustBootstrapAssessment assessment = await probe.assess(
      RevclustConfig(projectKey: _validSdkKey),
    );

    expect(
      assessment.disposition,
      RevclustBootstrapDisposition.bootstrapUnavailable,
    );
    expect(
      assessment.message,
      "Hosted bootstrap could not be completed successfully.",
    );
    expect(
      assessment.diagnostics?.message,
      "Hosted bootstrap could not be completed successfully.",
    );
    expect(assessment.diagnostics?.errorCategory, "bootstrap_unavailable");
    expect(
      assessment.diagnostics?.message,
      isNot(contains("sensitive_key")),
    );
    expect(
      assessment.diagnostics?.errorCategory,
      isNot(contains("sensitive_key")),
    );
  });
}

class _RecordingBootstrapAdapter implements HttpClientAdapter {
  _RecordingBootstrapAdapter({
    required this.statusCode,
    required this.responseBody,
  });

  final int statusCode;
  final String responseBody;

  String? lastRequestUri;
  String? lastRequestMethod;
  String? lastRequestBody;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequestUri = options.uri.toString();
    lastRequestMethod = options.method;
    lastRequestBody = await _readRequestBody(requestStream);

    return ResponseBody.fromString(
      responseBody,
      statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  Future<String> _readRequestBody(Stream<Uint8List>? requestStream) async {
    if (requestStream == null) {
      return "";
    }

    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final Uint8List chunk in requestStream) {
      builder.add(chunk);
    }
    return utf8.decode(builder.takeBytes());
  }
}

HttpRevclustBootstrapProbe _probeWithResponse({
  required int statusCode,
  required String responseBody,
}) {
  return _probeWithAdapter(
    _RecordingBootstrapAdapter(
      statusCode: statusCode,
      responseBody: responseBody,
    ),
  );
}

HttpRevclustBootstrapProbe _probeWithAdapter(
  HttpClientAdapter adapter, {
  DateTime Function()? utcNow,
}) {
  final Dio dio = Dio(
    BaseOptions(
      responseType: ResponseType.json,
      validateStatus: (_) => true,
    ),
  )..httpClientAdapter = adapter;

  return HttpRevclustBootstrapProbe(
    dio: dio,
    utcNow: utcNow,
  );
}

String _successBody({
  required String endpoint,
  required String viewerBaseUrl,
}) {
  return jsonEncode(<String, Object?>{
    "ok": true,
    "upload": <String, Object?>{
      "endpoint": endpoint,
      "auth_token": "incident_upload_auth_team_a",
      "usable_until": "2026-03-28T12:15:00.000Z",
    },
    "viewer_base_url": viewerBaseUrl,
  });
}
