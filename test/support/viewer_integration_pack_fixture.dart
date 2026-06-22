import "package:revclust_flutter_sdk/src/internal/revclust_internal.dart";
import "package:revclust_flutter_sdk/src/update_context/session_state_store.dart";

const String viewerIntegrationFixtureCaptureId =
    "cap_sdk_viewer_integration_20260309";
const String viewerIntegrationFixtureSessionId =
    "11111111-2222-4333-8444-555555555555";
const int viewerIntegrationFixtureTriggerUtcMs = 1773057600123;

Future<PackBuildResult> buildViewerIntegrationFixturePack() async {
  final _MutableCheckoutState state = _MutableCheckoutState();
  final RevclustSdk sdk = RevclustSdk(
    config: SdkConfig(
      appVersion: "3.1.0",
      build: "31042",
      appReleaseStage: "staging",
      stateHashSalt: "viewer-integration-salt",
    ),
    monotonicClockMs: () => 4100,
    runtimeConditionsProvider: _FixedRuntimeConditionsProvider(),
    stateSnapshotProvider: AllowlistedStateSnapshotProvider(
      appStateFields: <AppStateField>[
        AppStateField(
          key: "screen",
          readValue: () => state.screen,
        ),
        AppStateField(
          key: "step",
          readValue: () => state.step,
        ),
        AppStateField(
          key: "retry_banner_visible",
          readValue: () => state.retryBannerVisible,
        ),
      ],
      dataStateFields: <DataStateField>[
        DataStateField.value(
          key: "cart_count",
          readValue: () => state.cartCount,
        ),
        DataStateField.hashedDomainId(
          key: "order_id",
          readValue: () => state.orderId,
        ),
      ],
    ),
    sessionStateStore: _MemorySessionStateStore(
      lastSeenAppVersion: "3.0.9",
    ),
  );

  await sdk.initialize();

  sdk.recordScreenTransition(
    tMonoMs: 3600,
    fromScreen: "cart",
    toScreen: "checkout",
  );
  sdk.recordUiIntent(
    tMonoMs: 3700,
    name: "checkout.submit",
    attributes: <String, Object?>{
      "surface": "confirm_order",
      "cta": "place_order",
    },
  );
  sdk.recordUiIntent(
    tMonoMs: 3800,
    name: "checkout.retry_prompt_shown",
    attributes: <String, Object?>{
      "surface": "error_banner",
      "attempt": 2,
    },
  );
  sdk.recordNetworkEvent(
    tMonoMs: 3900,
    method: "POST",
    path: "/api/orders/12345/confirm?coupon=SPRING",
    routeTemplate: "/api/orders/:orderId/confirm",
    statusCode: 503,
    durationMs: 812,
    errorType: "timeout",
    errorMessage: "gateway timeout while confirming order",
  );

  final CaptureEnvelope capturedEnvelope = sdk.captureNow(
    reason: "checkout confirmation mismatch",
    expected: <String, Object?>{
      "order_status": "confirmed",
      "screen": "confirmation",
    },
    observed: <String, Object?>{
      "order_status": "retrying",
      "screen": "checkout",
    },
    signature: "checkout_confirmation_mismatch",
  );
  final PackBuildRequest request = await sdk.buildPackRequest(
    captureEnvelope: capturedEnvelope,
  );

  final CaptureEnvelope fixtureEnvelope = CaptureEnvelope(
    captureId: viewerIntegrationFixtureCaptureId,
    trigger: capturedEnvelope.trigger,
    triggerUtcMs: viewerIntegrationFixtureTriggerUtcMs,
    triggerMonoMs: capturedEnvelope.triggerMonoMs,
    timeline: capturedEnvelope.timeline,
    runtimeConditions: capturedEnvelope.runtimeConditions,
    stateSnapshot: capturedEnvelope.stateSnapshot,
  );

  final PackBuildRequest baseRequest = _copyRequest(
    request,
    captureEnvelope: fixtureEnvelope,
    sessionId: viewerIntegrationFixtureSessionId,
  );
  final PackBuilder builder = PackBuilder();
  final PackBuildResult baseline = builder.build(baseRequest);
  final PackBuildResult truncated = builder.build(
    _copyRequest(
      baseRequest,
      maxPackBytesGzip: baseline.gzipBytes.lengthInBytes - 1,
    ),
  );

  if (!truncated.truncated) {
    throw StateError("Expected viewer integration fixture to be truncated.");
  }

  return truncated;
}

PackBuildRequest _copyRequest(
  PackBuildRequest request, {
  CaptureEnvelope? captureEnvelope,
  String? sessionId,
  int? maxPackBytesGzip,
}) {
  return PackBuildRequest(
    captureEnvelope: captureEnvelope ?? request.captureEnvelope,
    sessionId: sessionId ?? request.sessionId,
    updateContextSnapshot: request.updateContextSnapshot,
    appVersion: request.appVersion,
    build: request.build,
    deviceModel: request.deviceModel,
    osVersion: request.osVersion,
    networkType: request.networkType,
    appReleaseStage: request.appReleaseStage,
    rttBucket: request.rttBucket,
    quality: request.quality,
    gitSha: request.gitSha,
    appState: request.appState,
    dataState: request.dataState,
    maxPackBytesGzip: maxPackBytesGzip ?? request.maxPackBytesGzip,
  );
}

class _FixedRuntimeConditionsProvider implements RuntimeConditionsProvider {
  @override
  Future<RuntimeConditionsSnapshot> resolve() async {
    return const RuntimeConditionsSnapshot(
      deviceModel: "Pixel 9 Pro",
      osVersion: "Android 16",
      networkType: "wifi",
    );
  }
}

class _MutableCheckoutState {
  String screen = "checkout";
  String step = "confirm";
  bool retryBannerVisible = true;
  int cartCount = 2;
  String orderId = "ord_12345";
}

class _MemorySessionStateStore implements SessionStateStore {
  _MemorySessionStateStore({
    String? lastSeenAppVersion,
  }) : _lastSeenAppVersion = lastSeenAppVersion;

  String? _lastSeenAppVersion;
  bool? _cleanShutdown;
  int? _lastCheckpointTimestampMs;

  @override
  Future<String?> readLastSeenAppVersion() async {
    return _lastSeenAppVersion;
  }

  @override
  Future<void> writeLastSeenAppVersion(String appVersion) async {
    _lastSeenAppVersion = appVersion;
  }

  @override
  Future<bool?> readCleanShutdown() async {
    return _cleanShutdown;
  }

  @override
  Future<void> writeCleanShutdown(bool isCleanShutdown) async {
    _cleanShutdown = isCleanShutdown;
  }

  @override
  Future<int?> readLastCheckpointTimestampMs() async {
    return _lastCheckpointTimestampMs;
  }

  @override
  Future<void> writeLastCheckpointTimestampMs(int timestampMs) async {
    _lastCheckpointTimestampMs = timestampMs;
  }
}
