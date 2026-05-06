import "dart:async";
import "dart:convert";
import "dart:typed_data";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter_sdk/src/public/revclust_bootstrap.dart";
import "package:revclust_flutter_sdk/src/public/revclust_config.dart";

const String _liveProjectKey = "rpk_uC4n8XQvJ9tR2mLsY7pKdB3fW6zHaNe1";
const String _missingProjectKey = "rpk_M2pQ8dLx7YvN1kTr4HsJc9_wZa6BgFe2";

void main() {
  test("hosted bootstrap success body matches the real pilot route contract",
      () async {
    final _RecordingBootstrapAdapter adapter = _RecordingBootstrapAdapter(
      statusCode: 200,
      responseBody: jsonEncode(<String, Object?>{
        "ok": true,
        "upload": <String, Object?>{
          "endpoint": "http://127.0.0.1:3000/api/pilot/packs",
          "auth_token": "pilot_upload_credential_team_a",
          "usable_until": "2026-03-28T12:15:00.000Z",
        },
        "viewer_base_url": "http://127.0.0.1:3000/pilot/packs",
      }),
    );
    final Dio dio = Dio()..httpClientAdapter = adapter;
    final HttpRevclustBootstrapProbe probe = HttpRevclustBootstrapProbe(
      dio: dio,
      utcNow: () => DateTime.parse("2026-03-28T12:00:00.000Z"),
    );

    final RevclustBootstrapAssessment assessment = await probe.assess(
      RevclustConfig(
        projectKey: _liveProjectKey,
        environment: RevclustEnvironment.development,
      ),
    );

    expect(assessment.disposition, RevclustBootstrapDisposition.ready);
    expect(
      assessment.lease?.uploadEndpoint,
      Uri.parse("http://127.0.0.1:3000/api/pilot/packs"),
    );
    expect(
      assessment.lease?.authToken,
      "pilot_upload_credential_team_a",
    );
    expect(
      assessment.lease?.usableUntil,
      DateTime.parse("2026-03-28T12:15:00.000Z"),
    );
    expect(
      assessment.lease?.viewerBaseUrl,
      Uri.parse("http://127.0.0.1:3000/pilot/packs"),
    );
    expect(
      adapter.lastRequestUri,
      "http://127.0.0.1:3000/api/pilot/sdk/bootstrap",
    );
    expect(adapter.lastRequestMethod, "POST");
    expect(
      jsonDecode(adapter.lastRequestBody ?? "") as Map<String, Object?>,
      <String, Object?>{
        "project_key": _liveProjectKey,
        "environment": "development",
      },
    );
  });

  test("404 project_not_provisioned maps to notProvisioned", () async {
    final HttpRevclustBootstrapProbe probe = _probeWithResponse(
      statusCode: 404,
      responseBody: jsonEncode(<String, Object?>{
        "ok": false,
        "error": <String, Object?>{
          "code": "project_not_provisioned",
          "message":
              "Project key is not provisioned for the selected environment.",
        },
      }),
    );

    final RevclustBootstrapAssessment assessment = await probe.assess(
      RevclustConfig(
        projectKey: _missingProjectKey,
        environment: RevclustEnvironment.development,
      ),
    );

    expect(
      assessment.disposition,
      RevclustBootstrapDisposition.notProvisioned,
    );
    expect(
      assessment.message,
      "Project key is not provisioned for the selected environment.",
    );
  });

  test("403 upload_auth_unavailable maps to uploadBlocked", () async {
    final HttpRevclustBootstrapProbe probe = _probeWithResponse(
      statusCode: 403,
      responseBody: jsonEncode(<String, Object?>{
        "ok": false,
        "error": <String, Object?>{
          "code": "upload_auth_unavailable",
          "message": "Pilot upload auth is temporarily blocked.",
        },
      }),
    );

    final RevclustBootstrapAssessment assessment = await probe.assess(
      RevclustConfig(
        projectKey: _liveProjectKey,
        environment: RevclustEnvironment.development,
      ),
    );

    expect(
      assessment.disposition,
      RevclustBootstrapDisposition.uploadBlocked,
    );
    expect(assessment.message, "Pilot upload auth is temporarily blocked.");
  });

  test("400 invalid_project_key maps to misconfigured", () async {
    final HttpRevclustBootstrapProbe probe = _probeWithResponse(
      statusCode: 400,
      responseBody: jsonEncode(<String, Object?>{
        "ok": false,
        "error": <String, Object?>{
          "code": "invalid_project_key",
          "message": "Project key is missing or invalid for hosted bootstrap.",
        },
      }),
    );

    final RevclustBootstrapAssessment assessment = await probe.assess(
      RevclustConfig(
        projectKey: _liveProjectKey,
        environment: RevclustEnvironment.development,
      ),
    );

    expect(
      assessment.disposition,
      RevclustBootstrapDisposition.misconfigured,
    );
    expect(
      assessment.message,
      "Project key is missing or invalid for hosted bootstrap.",
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
  final Dio dio = Dio(
    BaseOptions(
      responseType: ResponseType.json,
      validateStatus: (_) => true,
    ),
  )..httpClientAdapter = _RecordingBootstrapAdapter(
      statusCode: statusCode,
      responseBody: responseBody,
    );

  return HttpRevclustBootstrapProbe(dio: dio);
}
