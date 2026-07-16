import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter_sdk/src/internal/revclust_internal.dart";

final RegExp _uuidV4Pattern = RegExp(
  r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
  caseSensitive: false,
);

void main() {
  test("package imports and config instantiates", () {
    final SdkConfig config = SdkConfig();
    expect(config.enabled, isTrue);
    expect(config.bufferWindowSec, 30);
    expect(config.maxTimelineEvents, 200);
    expect(config.maxTimelineBytes, 256 * 1024);
    expect(config.maxStateKeys, 32);
    expect(config.maxStateBytes, 8 * 1024);
    expect(config.maxStringLen, 256);
  });

  test("sdk instantiates with config", () {
    final SdkConfig config = SdkConfig(
      enabled: false,
      bufferWindowSec: 120,
      maxTimelineEvents: 50,
      maxTimelineBytes: 4096,
      maxStateKeys: 12,
      maxStateBytes: 2048,
      maxStringLen: 64,
    );
    final RevclustSdk sdk = RevclustSdk(config: config);

    expect(sdk.config.bufferWindowSec, 120);
    expect(sdk.config.maxTimelineEvents, 50);
    expect(sdk.config.maxTimelineBytes, 4096);
    expect(sdk.config.maxStateKeys, 12);
    expect(sdk.config.maxStateBytes, 2048);
    expect(sdk.config.maxStringLen, 64);
    expect(sdk.config.enabled, isFalse);
  });

  test("sessionId is non-empty UUID v4", () {
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());

    expect(sdk.sessionId, isNotEmpty);
    expect(sdk.sessionId, matches(_uuidV4Pattern));
  });

  test("sessionId remains stable for same SDK instance", () {
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());

    expect(sdk.sessionId, equals(sdk.sessionId));
  });

  test("new SDK instance gets different sessionId", () {
    final RevclustSdk first = RevclustSdk(config: SdkConfig());
    final RevclustSdk second = RevclustSdk(config: SdkConfig());

    expect(first.sessionId, isNot(equals(second.sessionId)));
  });

  test("sdk config validates caps and sample rate", () {
    expect(
      () => SdkConfig(sessionSampleRate: -0.1),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => SdkConfig(sessionSampleRate: 1.1),
      throwsA(isA<ArgumentError>()),
    );
    expect(() => SdkConfig(bufferWindowSec: 0), throwsA(isA<ArgumentError>()));
    expect(
      () => SdkConfig(maxTimelineEvents: 0),
      throwsA(isA<ArgumentError>()),
    );
    expect(() => SdkConfig(maxTimelineBytes: 0), throwsA(isA<ArgumentError>()));
    expect(() => SdkConfig(maxStateKeys: 0), throwsA(isA<ArgumentError>()));
    expect(() => SdkConfig(maxStateBytes: 0), throwsA(isA<ArgumentError>()));
    expect(() => SdkConfig(maxStringLen: 0), throwsA(isA<ArgumentError>()));
    expect(() => SdkConfig(build: "   "), throwsA(isA<ArgumentError>()));
    expect(() => SdkConfig(gitSha: "   "), throwsA(isA<ArgumentError>()));
    expect(() => SdkConfig(gitSha: "not-a-sha"), throwsA(isA<ArgumentError>()));
  });

  test("sdk config normalizes optional build metadata", () {
    final SdkConfig config = SdkConfig(
      appVersion: "  1.2.3  ",
      build: "  2026.03.04  ",
      gitSha: "  ABCDEF1  ",
      stateHashSalt: "  app-salt  ",
    );
    expect(config.appVersion, "1.2.3");
    expect(config.build, "2026.03.04");
    expect(config.gitSha, "abcdef1");
    expect(config.stateHashSalt, "app-salt");
  });

  test("timeline event validates required fields", () {
    expect(
      () => TimelineEvent(eventType: "", tMonoMs: 0),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => TimelineEvent(eventType: "x", tMonoMs: -1),
      throwsA(isA<ArgumentError>()),
    );
  });

  test("lifecycle methods append event types with exact tMonoMs", () {
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());

    sdk.recordLifecycleForeground(tMonoMs: 1001);
    sdk.recordLifecycleBackground(
      tMonoMs: 1002,
      attributes: const <String, Object?>{"reason": "home"},
    );

    final List<TimelineEvent> snapshot = sdk.timelineSnapshot;
    expect(snapshot.length, 2);
    expect(
      snapshot.map((TimelineEvent event) => event.eventType).toList(),
      <String>["lifecycle.foreground", "lifecycle.background"],
    );
    expect(snapshot.map((TimelineEvent event) => event.tMonoMs).toList(), <int>[
      1001,
      1002,
    ]);
    expect(snapshot[1].attributes["reason"], "home");
  });

  test("screen transition records from/to and custom attributes", () {
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());
    final Map<String, Object?> callerAttributes = <String, Object?>{
      "flow": "checkout",
      "from": "overridden",
    };

    sdk.recordScreenTransition(
      tMonoMs: 2000,
      fromScreen: "cart",
      toScreen: "payment",
      attributes: callerAttributes,
    );

    final List<TimelineEvent> snapshot = sdk.timelineSnapshot;
    expect(snapshot.length, 1);
    expect(snapshot[0].eventType, "ui.screen_transition");
    expect(snapshot[0].tMonoMs, 2000);
    expect(snapshot[0].attributes, <String, Object?>{
      "flow": "checkout",
      "from": "cart",
      "to": "payment",
    });
    expect(callerAttributes["from"], "overridden");
  });

  test("ui intent records required name and custom attributes", () {
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());

    sdk.recordUiIntent(
      tMonoMs: 3000,
      name: "cta.tap",
      attributes: const <String, Object?>{"component": "buy_button"},
    );

    final List<TimelineEvent> snapshot = sdk.timelineSnapshot;
    expect(snapshot.length, 1);
    expect(snapshot[0].eventType, "ui.intent");
    expect(snapshot[0].tMonoMs, 3000);
    expect(snapshot[0].attributes, <String, Object?>{
      "component": "buy_button",
      "name": "cta.tap",
    });
  });

  test("empty required strings throw ArgumentError", () {
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());

    expect(
      () => sdk.recordScreenTransition(
        tMonoMs: 1,
        fromScreen: "",
        toScreen: "details",
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => sdk.recordScreenTransition(
        tMonoMs: 1,
        fromScreen: "home",
        toScreen: "",
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => sdk.recordUiIntent(tMonoMs: 1, name: ""),
      throwsA(isA<ArgumentError>()),
    );
  });

  test("negative tMonoMs throws ArgumentError across public recorders", () {
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());

    expect(
      () => sdk.recordLifecycleForeground(tMonoMs: -1),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => sdk.recordLifecycleBackground(tMonoMs: -1),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => sdk.recordScreenTransition(
        tMonoMs: -1,
        fromScreen: "home",
        toScreen: "details",
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => sdk.recordUiIntent(tMonoMs: -1, name: "cta.tap"),
      throwsA(isA<ArgumentError>()),
    );
  });

  test("recordNetworkEvent always writes sanitizedPath and uppercases method",
      () {
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());
    final Map<String, Object?> callerAttributes = <String, Object?>{
      "method": "caller-value",
      "custom": true,
    };

    sdk.recordNetworkEvent(
      tMonoMs: 4000,
      method: "get",
      path: "/users/123?expand=1",
      routeTemplate: " /users/{id} ",
      attributes: callerAttributes,
    );

    final TimelineEvent event = sdk.timelineSnapshot.single;
    expect(event.eventType, "network");
    expect(event.attributes["method"], "GET");
    expect(event.attributes["sanitizedPath"], "/users/{id}");
    expect(event.attributes["routeTemplate"], "/users/{id}");
    expect(event.attributes["custom"], isTrue);
    expect(callerAttributes["method"], "caller-value");
  });

  test(
    "recordNetworkEvent normalizes explicit non-empty sanitizedPath",
    () {
      final RevclustSdk sdk = RevclustSdk(config: SdkConfig());

      sdk.recordNetworkEvent(
        tMonoMs: 4100,
        method: "post",
        path: "/ignored/123",
        sanitizedPath: " /custom/123?expand=1#fragment ",
      );

      final TimelineEvent event = sdk.timelineSnapshot.single;
      expect(event.attributes["method"], "POST");
      expect(event.attributes["sanitizedPath"], "/custom/{id}");
    },
  );

  test(
    "recordNetworkEvent computes sanitizedPath when explicit value is empty",
    () {
      final RevclustSdk sdk = RevclustSdk(config: SdkConfig());

      sdk.recordNetworkEvent(
        tMonoMs: 4200,
        method: "put",
        path: "orders/123",
        sanitizedPath: "   ",
      );

      final TimelineEvent event = sdk.timelineSnapshot.single;
      expect(event.attributes["method"], "PUT");
      expect(event.attributes["sanitizedPath"], "orders/{id}");
    },
  );

  test("recordNetworkEvent includes optional fields when present", () {
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());
    final String longMessage = List<String>.filled(700, "x").join();

    sdk.recordNetworkEvent(
      tMonoMs: 4300,
      method: "delete",
      path: "/sessions/550e8400-e29b-41d4-a716-446655440000",
      routeTemplate: "",
      statusCode: 204,
      durationMs: 17,
      errorType: "socket",
      errorMessage: longMessage,
    );

    final TimelineEvent event = sdk.timelineSnapshot.single;
    expect(event.attributes["status"], 204);
    expect(event.attributes["duration_ms"], 17);
    expect(event.attributes.containsKey("statusCode"), isFalse);
    expect(event.attributes.containsKey("durationMs"), isFalse);
    expect(event.attributes["errorType"], "socket");
    expect((event.attributes["errorMessage"] as String).length, 512);
    expect(event.attributes.containsKey("routeTemplate"), isFalse);
  });

  test("recordNetworkEvent validates invalid inputs at runtime", () {
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());

    expect(
      () => sdk.recordNetworkEvent(tMonoMs: 1, method: "", path: "/x"),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => sdk.recordNetworkEvent(tMonoMs: 1, method: "GET"),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => sdk.recordNetworkEvent(
        tMonoMs: 1,
        method: "GET",
        path: "/x",
        durationMs: -1,
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => sdk.recordNetworkEvent(
        tMonoMs: 1,
        method: "GET",
        path: "/x",
        statusCode: 99,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test("recordNetworkEvent validates HTTP status range boundaries", () {
    final RevclustSdk sdk = RevclustSdk(config: SdkConfig());

    expect(
      () => sdk.recordNetworkEvent(
        tMonoMs: 1,
        method: "GET",
        path: "/x",
        statusCode: 99,
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => sdk.recordNetworkEvent(
        tMonoMs: 1,
        method: "GET",
        path: "/x",
        statusCode: 600,
      ),
      throwsA(isA<ArgumentError>()),
    );

    sdk.recordNetworkEvent(
        tMonoMs: 2, method: "GET", path: "/x", statusCode: 100);
    sdk.recordNetworkEvent(
        tMonoMs: 3, method: "GET", path: "/x", statusCode: 599);

    final List<TimelineEvent> snapshot = sdk.timelineSnapshot;
    expect(snapshot.length, 2);
    expect(snapshot[0].attributes["status"], 100);
    expect(snapshot[1].attributes["status"], 599);
  });

  test("mixed recording calls produce deterministic buffer order", () {
    final RevclustSdk sdk = RevclustSdk(
      config: SdkConfig(
        maxTimelineEvents: 10,
        maxTimelineBytes: 1024 * 1024,
      ),
    );

    sdk.recordUiIntent(tMonoMs: 500, name: "later");
    sdk.recordLifecycleForeground(tMonoMs: 100);
    sdk.recordScreenTransition(tMonoMs: 300, fromScreen: "a", toScreen: "b");
    sdk.recordLifecycleBackground(tMonoMs: 300);
    sdk.recordUiIntent(tMonoMs: 300, name: "same_ts_third");

    final List<TimelineEvent> snapshot = sdk.timelineSnapshot;
    expect(snapshot.length, 5);
    expect(
      snapshot.map((TimelineEvent event) => event.eventType).toList(),
      <String>[
        "lifecycle.foreground",
        "ui.screen_transition",
        "lifecycle.background",
        "ui.intent",
        "ui.intent",
      ],
    );
    expect(snapshot.map((TimelineEvent event) => event.tMonoMs).toList(), <int>[
      100,
      300,
      300,
      300,
      500,
    ]);
    expect(snapshot[1].attributes["from"], "a");
    expect(snapshot[1].attributes["to"], "b");
    expect(snapshot[3].attributes["name"], "same_ts_third");
    expect(snapshot[4].attributes["name"], "later");
  });
}
