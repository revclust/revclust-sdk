import "package:dio/dio.dart";

import "../core/revclust_sdk.dart";

/// Dio interceptor that records request outcome events into Revclust timeline.
class RevclustDioInterceptor extends Interceptor {
  RevclustDioInterceptor({
    required RevclustSdk sdk,
    this.routeTemplateExtraKey = "routeTemplate",
    int Function()? monotonicClockMs,
  })  : _sdk = sdk,
        _monotonicClockMs = monotonicClockMs ?? sdk.monotonicClockMs;

  final RevclustSdk _sdk;
  final String routeTemplateExtraKey;
  final int Function() _monotonicClockMs;

  static const String _requestStartExtraKey = "_revclust_request_start_mono_ms";

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_requestStartExtraKey] = _monotonicClockMs();
    handler.next(options);
  }

  @override
  void onResponse(
      Response<dynamic> response, ResponseInterceptorHandler handler) {
    final RequestOptions options = response.requestOptions;
    final int? startMonoMs = _extractStartMonoMs(options);
    final int nowMs = _monotonicClockMs();
    _sdk.recordNetworkEvent(
      tMonoMs: nowMs,
      method: options.method,
      url: options.uri.toString(),
      routeTemplate: _extractRouteTemplate(options),
      statusCode: response.statusCode,
      durationMs:
          _computeDurationMs(startMonoMs: startMonoMs, endMonoMs: nowMs),
      attributes: _buildTimingAttributes(
        startMonoMs: startMonoMs,
        endMonoMs: nowMs,
      ),
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final RequestOptions options = err.requestOptions;
    final int? startMonoMs = _extractStartMonoMs(options);
    final int nowMs = _monotonicClockMs();
    _sdk.recordNetworkEvent(
      tMonoMs: nowMs,
      method: options.method,
      url: options.uri.toString(),
      routeTemplate: _extractRouteTemplate(options),
      statusCode: err.response?.statusCode,
      durationMs:
          _computeDurationMs(startMonoMs: startMonoMs, endMonoMs: nowMs),
      errorType: err.type.name,
      errorMessage: err.message ?? err.error?.toString(),
      attributes: _buildTimingAttributes(
        startMonoMs: startMonoMs,
        endMonoMs: nowMs,
      ),
    );
    handler.next(err);
  }

  int? _extractStartMonoMs(RequestOptions options) {
    final Object? maybeStart = options.extra[_requestStartExtraKey];
    if (maybeStart is! int || maybeStart < 0) {
      return null;
    }
    return maybeStart;
  }

  int? _computeDurationMs({required int? startMonoMs, required int endMonoMs}) {
    if (startMonoMs == null || endMonoMs < startMonoMs) {
      return null;
    }
    return endMonoMs - startMonoMs;
  }

  Map<String, Object?> _buildTimingAttributes({
    required int? startMonoMs,
    required int endMonoMs,
  }) {
    if (startMonoMs == null) {
      return const <String, Object?>{};
    }
    return <String, Object?>{
      "start_mono_ms": startMonoMs,
      "end_mono_ms": endMonoMs,
    };
  }

  String? _extractRouteTemplate(RequestOptions options) {
    final Object? routeTemplate = options.extra[routeTemplateExtraKey];
    if (routeTemplate is! String) {
      return null;
    }
    final String normalized = routeTemplate.trim();
    if (normalized.isEmpty) {
      return null;
    }
    return normalized;
  }
}
