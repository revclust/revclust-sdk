import "dart:ui" show ErrorCallback, PlatformDispatcher;

import "package:flutter/foundation.dart";
import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter_sdk/src/internal/revclust_internal.dart";

void main() {
  late FlutterExceptionHandler? originalFlutterHandler;
  late ErrorCallback? originalPlatformHandler;

  setUp(() {
    originalFlutterHandler = FlutterError.onError;
    originalPlatformHandler = PlatformDispatcher.instance.onError;
  });

  tearDown(() {
    FlutterError.onError = originalFlutterHandler;
    PlatformDispatcher.instance.onError = originalPlatformHandler;
  });

  test("install hooks chains prior handlers and preserves platform return", () {
    int flutterPriorCalls = 0;
    int platformPriorCalls = 0;

    void priorFlutterHandler(FlutterErrorDetails details) {
      flutterPriorCalls += 1;
    }

    bool priorPlatformHandler(Object error, StackTrace stackTrace) {
      platformPriorCalls += 1;
      return true;
    }

    FlutterError.onError = priorFlutterHandler;
    PlatformDispatcher.instance.onError = priorPlatformHandler;

    final List<CaptureEnvelope> emitted = <CaptureEnvelope>[];
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());
    final UnhandledExceptionHooks hooks = sdk.installUnhandledExceptionHooks(
      onCapture: emitted.add,
    );

    final FlutterExceptionHandler installedFlutterHandler =
        FlutterError.onError!;
    final ErrorCallback installedPlatformHandler =
        PlatformDispatcher.instance.onError!;

    installedFlutterHandler(FlutterErrorDetails(exception: StateError("boom")));
    final bool handled =
        installedPlatformHandler(ArgumentError("bad"), StackTrace.current);

    expect(flutterPriorCalls, 1);
    expect(platformPriorCalls, 1);
    expect(handled, isTrue);
    expect(emitted, hasLength(2));

    hooks.restore();
  });

  test(
      "single unhandled invocation emits exactly one capture with locked metadata",
      () {
    FlutterError.onError = null;
    PlatformDispatcher.instance.onError = null;

    final List<CaptureEnvelope> emitted = <CaptureEnvelope>[];
    final RevclustSdk sdk = RevclustSdk(
      config: SdkConfig(),
      monotonicClockMs: () => 4000,
    );
    sdk.recordUiIntent(tMonoMs: 3900, name: "before_error");

    sdk.installUnhandledExceptionHooks(onCapture: emitted.add);

    final ErrorCallback installedPlatformHandler =
        PlatformDispatcher.instance.onError!;
    final _VeryLongError error =
        _VeryLongError(List<String>.filled(700, "x").join());
    final bool handled = installedPlatformHandler(error, StackTrace.current);

    expect(handled, isFalse);
    expect(emitted, hasLength(1));

    final CaptureEnvelope envelope = emitted.single;
    expect(envelope.trigger.type, "unhandled_exception");
    expect(envelope.trigger.reason, isNull);
    expect(envelope.trigger.attributes["failure_kind"], "unhandled_exception");
    expect(envelope.trigger.observed, isA<Map<String, Object?>>());
    final Map<String, Object?> observed =
        envelope.trigger.observed! as Map<String, Object?>;
    expect(observed["exception_type"], "_VeryLongError");
    expect(observed["message"], List<String>.filled(512, "x").join());
    expect((observed["message"] as String).length, 512);
    expect(envelope.trigger.expected, isNull);
    expect(envelope.trigger.signature, isNull);
  });

  test("multiple unhandled invocations emit multiple captures without dedupe",
      () {
    FlutterError.onError = null;
    PlatformDispatcher.instance.onError = null;

    final List<CaptureEnvelope> emitted = <CaptureEnvelope>[];
    final RevclustSdk sdk = RevclustSdk(
      config: SdkConfig(),
      monotonicClockMs: _sequenceClock(<int>[100, 101, 102]),
    );

    sdk.installUnhandledExceptionHooks(onCapture: emitted.add);

    final ErrorCallback installedPlatformHandler =
        PlatformDispatcher.instance.onError!;
    installedPlatformHandler(StateError("same"), StackTrace.current);
    installedPlatformHandler(StateError("same"), StackTrace.current);
    installedPlatformHandler(StateError("same"), StackTrace.current);

    expect(emitted, hasLength(3));
    expect(
      emitted.map((CaptureEnvelope envelope) => envelope.trigger.type).toList(),
      <String>[
        "unhandled_exception",
        "unhandled_exception",
        "unhandled_exception",
      ],
    );
  });

  test("uninstall restores previous flutter and platform handlers", () {
    void priorFlutterHandler(FlutterErrorDetails details) {}

    bool priorPlatformHandler(Object error, StackTrace stackTrace) => true;

    FlutterError.onError = priorFlutterHandler;
    PlatformDispatcher.instance.onError = priorPlatformHandler;

    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());
    final UnhandledExceptionHooks hooks = sdk.installUnhandledExceptionHooks(
      onCapture: (CaptureEnvelope _) {},
    );

    final FlutterExceptionHandler installedFlutterHandler =
        FlutterError.onError!;
    final ErrorCallback installedPlatformHandler =
        PlatformDispatcher.instance.onError!;
    expect(identical(installedFlutterHandler, priorFlutterHandler), isFalse);
    expect(identical(installedPlatformHandler, priorPlatformHandler), isFalse);

    hooks.uninstall();

    expect(identical(FlutterError.onError, priorFlutterHandler), isTrue);
    expect(
      identical(PlatformDispatcher.instance.onError, priorPlatformHandler),
      isTrue,
    );
  });
}

class _VeryLongError {
  _VeryLongError(this.message);

  final String message;

  @override
  String toString() => message;
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
