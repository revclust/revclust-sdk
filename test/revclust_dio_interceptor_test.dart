import "dart:async";
import "dart:typed_data";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter_sdk/revclust_flutter_sdk.dart";

void main() {
  test("success response emits network event with expected attributes",
      () async {
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());
    final Dio dio = Dio(BaseOptions(baseUrl: "https://api.example.com"));
    dio.httpClientAdapter = _SuccessAdapter(statusCode: 200);
    dio.interceptors.add(
      RevclustDioInterceptor(
        sdk: sdk,
        monotonicClockMs: _sequenceClock(<int>[100, 145]),
      ),
    );

    final Response<dynamic> response = await dio.get<dynamic>(
      "/users/123?expand=1",
      options: Options(
        method: "get",
        extra: <String, Object?>{"routeTemplate": " /users/{id} "},
      ),
    );

    expect(response.statusCode, 200);
    final TimelineEvent event = sdk.timelineSnapshot.single;
    expect(event.eventType, "network");
    expect(event.tMonoMs, 145);
    expect(event.attributes["method"], "GET");
    expect(event.attributes["sanitizedPath"], "/users/{id}");
    expect(event.attributes["routeTemplate"], "/users/{id}");
    expect(event.attributes["status"], 200);
    expect(event.attributes["duration_ms"], 45);
    expect(event.attributes["start_mono_ms"], 100);
    expect(event.attributes["end_mono_ms"], 145);
    expect(event.attributes.containsKey("statusCode"), isFalse);
    expect(event.attributes.containsKey("durationMs"), isFalse);
    expect(event.attributes.containsKey("errorType"), isFalse);
    expect(event.attributes.containsKey("errorMessage"), isFalse);
  });

  test("error response emits network event with error metadata", () async {
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());
    final Dio dio = Dio(BaseOptions(baseUrl: "https://api.example.com"));
    dio.httpClientAdapter = _ErrorAdapter(
      statusCode: 503,
      message: "Upstream timeout",
    );
    dio.interceptors.add(
      RevclustDioInterceptor(
        sdk: sdk,
        monotonicClockMs: _sequenceClock(<int>[10, 27]),
      ),
    );

    await expectLater(
      dio.post<dynamic>("/tokens/abcdef1234567890abcdef1234567890"),
      throwsA(isA<DioException>()),
    );

    final TimelineEvent event = sdk.timelineSnapshot.single;
    expect(event.eventType, "network");
    expect(event.tMonoMs, 27);
    expect(event.attributes["method"], "POST");
    expect(event.attributes["sanitizedPath"], "/tokens/{id}");
    expect(event.attributes["status"], 503);
    expect(event.attributes["duration_ms"], 17);
    expect(event.attributes["start_mono_ms"], 10);
    expect(event.attributes["end_mono_ms"], 27);
    expect(event.attributes.containsKey("statusCode"), isFalse);
    expect(event.attributes.containsKey("durationMs"), isFalse);
    expect(event.attributes["errorType"], "badResponse");
    expect(event.attributes["errorMessage"], "Upstream timeout");
  });

  test("default interceptor clock uses SDK monotonic source consistently",
      () async {
    final RevclustSdk sdk = RevclustSdk(
      config: SdkConfig(),
      monotonicClockMs: _sequenceClock(<int>[200, 260]),
    );
    final Dio dio = Dio(BaseOptions(baseUrl: "https://api.example.com"));
    dio.httpClientAdapter = _SuccessAdapter(statusCode: 200);
    dio.interceptors.add(RevclustDioInterceptor(sdk: sdk));

    await dio.get<dynamic>("/accounts/123");

    final TimelineEvent event = sdk.timelineSnapshot.single;
    expect(event.tMonoMs, 260);
    expect(event.attributes["start_mono_ms"], 200);
    expect(event.attributes["end_mono_ms"], 260);
    expect(event.attributes["duration_ms"], 60);
  });

  test("routeTemplate is read from RequestOptions.extra when non-empty",
      () async {
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());
    final Dio dio = Dio(BaseOptions(baseUrl: "https://api.example.com"));
    dio.httpClientAdapter = _SuccessAdapter(statusCode: 201);
    dio.interceptors.add(
      RevclustDioInterceptor(
        sdk: sdk,
        monotonicClockMs: _sequenceClock(<int>[1, 5]),
      ),
    );

    await dio.put<dynamic>(
      "/orders/999",
      options: Options(
        extra: <String, Object?>{"routeTemplate": " /orders/{id} "},
      ),
    );

    final TimelineEvent event = sdk.timelineSnapshot.single;
    expect(event.attributes["routeTemplate"], "/orders/{id}");
  });
}

int Function() _sequenceClock(List<int> values) {
  int index = 0;
  return () {
    final int value = values[index];
    if (index < values.length - 1) {
      index += 1;
    }
    return value;
  };
}

class _SuccessAdapter implements HttpClientAdapter {
  _SuccessAdapter({required this.statusCode});

  final int statusCode;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      "{\"ok\":true}",
      statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }
}

class _ErrorAdapter implements HttpClientAdapter {
  _ErrorAdapter({required this.statusCode, required this.message});

  final int statusCode;
  final String message;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException(
      requestOptions: options,
      response: Response<dynamic>(
        requestOptions: options,
        statusCode: statusCode,
        statusMessage: "failure",
      ),
      type: DioExceptionType.badResponse,
      message: message,
    );
  }
}
