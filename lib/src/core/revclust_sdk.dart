import "dart:async" show unawaited;
import "dart:ui" show ErrorCallback, PlatformDispatcher;

import "package:flutter/foundation.dart";
import "package:uuid/uuid.dart";

import "../capture/capture_envelope.dart";
import "../capture/capture_trigger.dart";
import "../checkpoint/checkpoint_coordinator.dart";
import "../config/sdk_config.dart";
import "../events/event_types.dart";
import "../events/timeline_event.dart";
import "../network/path_sanitizer.dart";
import "../observability/sdk_logger.dart";
import "../pack/pack_build_request.dart";
import "../pack/pack_build_result.dart";
import "../pack/pack_builder.dart";
import "../persistence/local_pack_repository.dart";
import "../runtime/runtime_conditions.dart";
import "../state/state_snapshot.dart";
import "../timeline/ring_buffer.dart";
import "../update_context/update_context_snapshot.dart";
import "../update_context/session_state_store.dart";

/// Low-level SDK entrypoint for capture, checkpointing, and pack building.
class RevclustSdk {
  static const String _invariantFailureTriggerType = "invariant_failure";

  /// Creates an SDK instance with static configuration.
  RevclustSdk({
    required this.config,
    int Function()? monotonicClockMs,
    SessionStateStore? sessionStateStore,
    LocalPackRepository? localPackRepository,
    CheckpointCoordinator? checkpointCoordinator,
    PackBuilder? packBuilder,
    RuntimeConditionsProvider? runtimeConditionsProvider,
    AllowlistedStateSnapshotProvider? stateSnapshotProvider,
  })  : _sessionId = _uuid.v4(),
        _packBuilder = packBuilder ?? PackBuilder(logger: config.logger),
        _timeline = TimelineRingBuffer(
          maxEvents: config.maxTimelineEvents,
          maxBytes: config.maxTimelineBytes,
        ),
        _monotonicClockMsOverride = monotonicClockMs,
        _runtimeConditionsProvider =
            runtimeConditionsProvider ?? FlutterRuntimeConditionsProvider(),
        _stateSnapshotProvider = stateSnapshotProvider ??
            AllowlistedStateSnapshotProvider(logger: config.logger),
        _sessionStateStore =
            sessionStateStore ?? SharedPreferencesSessionStateStore() {
    if (_stateSnapshotProvider.requiresHashSalt &&
        config.stateHashSalt == null) {
      throw ArgumentError(
        "SdkConfig.stateHashSalt is required when using hashed domain IDs.",
      );
    }

    if (checkpointCoordinator != null) {
      checkpointCoordinator.startTicker();
      _checkpointCoordinator = checkpointCoordinator;
      return;
    }

    if (localPackRepository == null) {
      return;
    }

    final CheckpointCoordinator createdCheckpointCoordinator =
        CheckpointCoordinator(
      packBuilder: _packBuilder,
      persistPack: (PackBuildResult result) => _persistPendingPack(
        localPackRepository,
        result,
      ),
      sessionStateStore: _sessionStateStore,
      captureCheckpointEnvelope: _captureCheckpointEnvelope,
      buildPackRequest: _buildCheckpointPackRequest,
      logger: config.logger,
    );
    createdCheckpointCoordinator.startTicker();
    _checkpointCoordinator = createdCheckpointCoordinator;
  }

  /// Runtime configuration used by this SDK instance.
  final SdkConfig config;

  static const Uuid _uuid = Uuid();
  static const int _networkErrorMessageMaxLength = 512;
  static const int _unhandledObservedMaxLength = 512;
  static const String _manualTriggerType = "manual";
  static const String _programmaticTriggerType = "programmatic";
  static const String _unhandledExceptionTriggerType = "unhandled_exception";
  static const String _previousSessionUncleanExitTriggerType =
      "previous_session_unclean_exit";
  static const String _checkpointTriggerType = checkpointTriggerType;
  static const String _lastCheckpointAgeMsKey = "last_checkpoint_age_ms";

  final String _sessionId;
  final PackBuilder _packBuilder;
  final TimelineRingBuffer _timeline;
  final Stopwatch _monotonicClock = Stopwatch()..start();
  final int Function()? _monotonicClockMsOverride;
  final RuntimeConditionsProvider _runtimeConditionsProvider;
  final AllowlistedStateSnapshotProvider _stateSnapshotProvider;
  final SessionStateStore _sessionStateStore;
  CheckpointCoordinator? _checkpointCoordinator;
  UpdateContextSnapshot _updateContextSnapshot = UpdateContextSnapshot.unknown;
  bool _hasProcessedPreviousSessionExitState = false;
  bool _hasEmittedPreviousSessionUncleanExitCapture = false;
  bool _isDisposed = false;

  /// Session identifier scoped to this SDK runtime instance.
  ///
  /// This is SDK/session scope for now and will be added to pack artifacts
  /// during serialization.
  String get sessionId => _sessionId;

  /// Monotonic clock source used by SDK-recorded events.
  int monotonicClockMs() {
    return _monotonicClockMsOverride?.call() ??
        _monotonicClock.elapsedMilliseconds;
  }

  /// Computes and persists update-context on app startup.
  ///
  /// When provided, [appVersion] overrides [SdkConfig.appVersion].
  Future<UpdateContextSnapshot> initialize({
    String? appVersion,
    void Function(CaptureEnvelope envelope)? onCapture,
  }) async {
    await _initializePreviousSessionExitState(onCapture: onCapture);
    return initializeUpdateContext(appVersion: appVersion);
  }

  /// Computes and persists update-context without previous-session handling.
  ///
  /// This is the narrow path used when a caller only needs build/version
  /// reproduction conditions and has not opted into lifecycle exit capture.
  Future<UpdateContextSnapshot> initializeUpdateContext({
    String? appVersion,
  }) async {
    final String? currentAppVersion = _resolveCurrentAppVersion(
      appVersion: appVersion,
    );

    if (currentAppVersion == null) {
      _updateContextSnapshot = UpdateContextSnapshot.unknown;
      return _updateContextSnapshot;
    }

    final String? lastSeenVersion =
        await _sessionStateStore.readLastSeenAppVersion();

    if (lastSeenVersion == null) {
      await _sessionStateStore.writeLastSeenAppVersion(currentAppVersion);
      _updateContextSnapshot = UpdateContextSnapshot.freshInstall;
      return _updateContextSnapshot;
    }

    if (lastSeenVersion == currentAppVersion) {
      _updateContextSnapshot = UpdateContextSnapshot.unknown;
      return _updateContextSnapshot;
    }

    await _sessionStateStore.writeLastSeenAppVersion(currentAppVersion);
    _updateContextSnapshot = UpdateContextSnapshot.update(
      prevAppVersion: lastSeenVersion,
    );
    return _updateContextSnapshot;
  }

  /// Marks this session as cleanly shut down and updates checkpoint time.
  Future<void> markCleanShutdown() async {
    _checkpointCoordinator?.stopTicker();
    final int nowUtcMs = DateTime.now().millisecondsSinceEpoch;
    await _sessionStateStore.writeCleanShutdown(true);
    await _sessionStateStore.writeLastCheckpointTimestampMs(nowUtcMs);
  }

  /// Stops checkpoint cadence orchestration for this SDK instance.
  ///
  /// Safe to call more than once.
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _checkpointCoordinator?.stopTicker();
    _checkpointCoordinator = null;
  }

  /// Adds a timeline event into the in-memory ring buffer.
  void _addTimelineEvent(TimelineEvent event) {
    _timeline.add(event);
  }

  /// Records a foreground lifecycle transition.
  void recordLifecycleForeground({
    required int tMonoMs,
    Map<String, Object?> attributes = const <String, Object?>{},
  }) {
    _recordTimelineEvent(
      eventType: RevclustEventTypes.lifecycleForeground,
      tMonoMs: tMonoMs,
      attributes: attributes,
    );
  }

  /// Records a background lifecycle transition.
  void recordLifecycleBackground({
    required int tMonoMs,
    Map<String, Object?> attributes = const <String, Object?>{},
  }) {
    _recordTimelineEvent(
      eventType: RevclustEventTypes.lifecycleBackground,
      tMonoMs: tMonoMs,
      attributes: attributes,
    );
    final CheckpointCoordinator? checkpointCoordinator = _checkpointCoordinator;
    if (checkpointCoordinator != null) {
      final CaptureEnvelope checkpointEnvelope = _captureCheckpointEnvelope(
        checkpointReasonCadenceBackground,
      );
      unawaited(
        checkpointCoordinator.onBackgroundTransition(
          envelope: checkpointEnvelope,
        ),
      );
    }
  }

  /// Records a UI screen transition.
  void recordScreenTransition({
    required int tMonoMs,
    required String fromScreen,
    required String toScreen,
    Map<String, Object?> attributes = const <String, Object?>{},
  }) {
    _requireNonEmptyString(fromScreen, "fromScreen");
    _requireNonEmptyString(toScreen, "toScreen");

    _recordTimelineEvent(
      eventType: RevclustEventTypes.uiScreenTransition,
      tMonoMs: tMonoMs,
      attributes: <String, Object?>{
        ...attributes,
        "from": fromScreen,
        "to": toScreen,
      },
    );
  }

  /// Records a developer-tagged UI intent event.
  void recordUiIntent({
    required int tMonoMs,
    required String name,
    Map<String, Object?> attributes = const <String, Object?>{},
  }) {
    _requireNonEmptyString(name, "name");

    _recordTimelineEvent(
      eventType: RevclustEventTypes.uiIntent,
      tMonoMs: tMonoMs,
      attributes: <String, Object?>{...attributes, "name": name},
    );
  }

  /// Records a network event as an escape hatch for non-intercepted clients.
  void recordNetworkEvent({
    int? tMonoMs,
    required String method,
    String? path,
    String? url,
    String? sanitizedPath,
    String? routeTemplate,
    int? statusCode,
    int? durationMs,
    String? errorType,
    String? errorMessage,
    Map<String, Object?> attributes = const <String, Object?>{},
  }) {
    final int eventTimestamp = tMonoMs ?? monotonicClockMs();
    final String normalizedMethod =
        _normalizeRequiredString(method, "method").toUpperCase();
    final String resolvedSanitizedPath = _resolveSanitizedPath(
      path: path,
      url: url,
      sanitizedPath: sanitizedPath,
    );

    if (statusCode != null && (statusCode < 100 || statusCode > 599)) {
      throw ArgumentError.value(statusCode, "statusCode", "must be 100..599");
    }
    if (durationMs != null && durationMs < 0) {
      throw ArgumentError.value(durationMs, "durationMs", "must be >= 0");
    }

    final Map<String, Object?> eventAttributes = Map<String, Object?>.from(
      attributes,
    );
    eventAttributes["method"] = normalizedMethod;
    eventAttributes["sanitizedPath"] = resolvedSanitizedPath;

    final String? normalizedRouteTemplate = _normalizeNullableString(
      routeTemplate,
    );
    if (normalizedRouteTemplate != null) {
      eventAttributes["routeTemplate"] = normalizedRouteTemplate;
    }
    if (statusCode != null) {
      eventAttributes["status"] = statusCode;
    }
    if (durationMs != null) {
      eventAttributes["duration_ms"] = durationMs;
    }

    final String? normalizedErrorType = _normalizeNullableString(errorType);
    if (normalizedErrorType != null) {
      eventAttributes["errorType"] = normalizedErrorType;
    }
    final String? normalizedErrorMessage = _normalizeNullableString(
      errorMessage,
    );
    if (normalizedErrorMessage != null) {
      eventAttributes["errorMessage"] = _truncateString(
        normalizedErrorMessage,
        _networkErrorMessageMaxLength,
      );
    }

    _recordTimelineEvent(
      eventType: RevclustEventTypes.network,
      tMonoMs: eventTimestamp,
      attributes: eventAttributes,
    );
  }

  /// Read-only timeline snapshot in deterministic buffer order.
  List<TimelineEvent> get timelineSnapshot => _timeline.snapshot;

  /// Current retained timeline event count.
  int get timelineEventCount => _timeline.length;

  /// Current retained estimated timeline bytes.
  int get timelineEstimatedBytes => _timeline.estimatedBytes;

  /// Current update-context snapshot computed during [initialize].
  UpdateContextSnapshot get updateContextSnapshot => _updateContextSnapshot;

  /// Builds a pack request using runtime conditions snapped on the envelope.
  Future<PackBuildRequest> buildPackRequest({
    required CaptureEnvelope captureEnvelope,
  }) async {
    final RuntimeConditionsSnapshot runtimeConditions =
        await captureEnvelope.runtimeConditions.resolve();
    final StateSnapshot stateSnapshot =
        await captureEnvelope.stateSnapshot.resolve();
    return PackBuildRequest(
      captureEnvelope: captureEnvelope,
      sessionId: _sessionId,
      updateContextSnapshot: _updateContextSnapshot,
      appVersion: config.appVersion,
      build: config.build,
      gitSha: config.gitSha,
      deviceModel: runtimeConditions.deviceModel,
      osVersion: runtimeConditions.osVersion,
      networkType: runtimeConditions.networkType,
      appReleaseStage: config.appReleaseStage,
      appState: stateSnapshot.appState,
      dataState: stateSnapshot.dataState,
    );
  }

  /// Builds a pack payload + gzip bytes from a captured envelope.
  Future<PackBuildResult> buildPack({
    required CaptureEnvelope captureEnvelope,
  }) async {
    final PackBuildRequest request = await buildPackRequest(
      captureEnvelope: captureEnvelope,
    );
    return _packBuilder.build(request);
  }

  /// Captures an in-memory envelope using a programmatic trigger.
  CaptureEnvelope captureNow({
    required String reason,
    Object? expected,
    Object? observed,
    String? signature,
    Map<String, Object?> triggerAttributes = const <String, Object?>{},
  }) {
    return _captureWithTrigger(
      triggerType: _programmaticTriggerType,
      reason: reason,
      expected: expected,
      observed: observed,
      signature: signature,
      triggerAttributes: triggerAttributes,
    );
  }

  /// Captures an in-memory envelope using a manual trigger.
  CaptureEnvelope captureManual({
    required String reason,
    Object? expected,
    Object? observed,
    String? signature,
    Map<String, Object?> triggerAttributes = const <String, Object?>{},
  }) {
    return _captureWithTrigger(
      triggerType: _manualTriggerType,
      reason: reason,
      expected: expected,
      observed: observed,
      signature: signature,
      triggerAttributes: triggerAttributes,
    );
  }

  /// Captures an app-owned invariant failure using factual trigger fields.
  CaptureEnvelope captureInvariantFailure({
    required String failureKind,
    required String subjectKind,
    required String subjectValue,
    required Object? expected,
    required Object? observed,
  }) {
    return _captureWithTrigger(
      triggerType: _invariantFailureTriggerType,
      expected: expected,
      observed: observed,
      triggerAttributes: <String, Object?>{
        "failure_kind": failureKind,
        "subject": <String, Object?>{
          "kind": subjectKind,
          "value": subjectValue,
        },
      },
    );
  }

  /// Installs best-effort hooks for framework-level unhandled exceptions.
  ///
  /// The returned [UnhandledExceptionHooks] can restore previous handlers.
  UnhandledExceptionHooks installUnhandledExceptionHooks({
    required void Function(CaptureEnvelope envelope) onCapture,
  }) {
    final FlutterExceptionHandler? previousFlutterHandler =
        FlutterError.onError;
    final ErrorCallback? previousPlatformHandler =
        PlatformDispatcher.instance.onError;

    late final FlutterExceptionHandler flutterHandler;
    flutterHandler = (FlutterErrorDetails details) {
      onCapture(_captureUnhandledException(details.exception));
      previousFlutterHandler?.call(details);
    };

    late final ErrorCallback platformHandler;
    platformHandler = (Object error, StackTrace stackTrace) {
      onCapture(_captureUnhandledException(error));
      if (previousPlatformHandler == null) {
        return false;
      }
      return previousPlatformHandler(error, stackTrace);
    };

    FlutterError.onError = flutterHandler;
    PlatformDispatcher.instance.onError = platformHandler;

    return UnhandledExceptionHooks._(
      restoreHandlers: () {
        if (identical(FlutterError.onError, flutterHandler)) {
          FlutterError.onError = previousFlutterHandler;
        }
        if (identical(PlatformDispatcher.instance.onError, platformHandler)) {
          PlatformDispatcher.instance.onError = previousPlatformHandler;
        }
      },
    );
  }

  void _recordTimelineEvent({
    required String eventType,
    required int tMonoMs,
    required Map<String, Object?> attributes,
  }) {
    _requireNonNegativeTimestamp(tMonoMs);
    final Map<String, Object?> copiedAttributes = Map<String, Object?>.from(
      attributes,
    );
    _addTimelineEvent(
      TimelineEvent(
        eventType: eventType,
        tMonoMs: tMonoMs,
        attributes: copiedAttributes,
      ),
    );

    final CheckpointCoordinator? checkpointCoordinator = _checkpointCoordinator;
    if (checkpointCoordinator != null) {
      unawaited(checkpointCoordinator.onEventRecorded());
    }
  }

  CaptureEnvelope _captureCheckpointEnvelope(String reason) {
    return _captureWithTrigger(
      triggerType: _checkpointTriggerType,
      reason: reason,
    );
  }

  Future<PackBuildRequest> _buildCheckpointPackRequest(
    CaptureEnvelope envelope,
  ) {
    return buildPackRequest(captureEnvelope: envelope);
  }

  CaptureEnvelope _captureWithTrigger({
    required String triggerType,
    String? reason,
    Object? expected,
    Object? observed,
    String? signature,
    Map<String, Object?> triggerAttributes = const <String, Object?>{},
  }) {
    final int triggerUtcMs = DateTime.now().millisecondsSinceEpoch;
    final int triggerMonoMs = monotonicClockMs();
    final List<TimelineEvent> preWindowTimeline = _slicePreWindowTimeline(
      triggerMonoMs: triggerMonoMs,
    );

    return CaptureEnvelope(
      captureId: _uuid.v4(),
      trigger: CaptureTrigger(
        type: triggerType,
        reason: reason,
        expected: expected,
        observed: observed,
        signature: signature,
        attributes: triggerAttributes,
      ),
      triggerUtcMs: triggerUtcMs,
      triggerMonoMs: triggerMonoMs,
      timeline: preWindowTimeline,
      runtimeConditions: CapturedRuntimeConditions.capture(
        _resolveRuntimeConditions,
      ),
      stateSnapshot: CapturedStateSnapshot.future(_resolveStateSnapshot()),
    );
  }

  CaptureEnvelope _captureUnhandledException(Object error) {
    return _captureWithTrigger(
      triggerType: _unhandledExceptionTriggerType,
      observed: <String, Object?>{
        "exception_type": error.runtimeType.toString(),
        "message":
            _truncateString(error.toString(), _unhandledObservedMaxLength),
      },
      triggerAttributes: const <String, Object?>{
        "failure_kind": _unhandledExceptionTriggerType,
      },
    );
  }

  List<TimelineEvent> _slicePreWindowTimeline({required int triggerMonoMs}) {
    final int preWindowMs = config.bufferWindowSec * 1000;
    return _timeline.snapshot.where((TimelineEvent event) {
      if (event.tMonoMs > triggerMonoMs) {
        return false;
      }
      return triggerMonoMs - event.tMonoMs <= preWindowMs;
    }).toList(growable: false);
  }

  Future<void> _initializePreviousSessionExitState({
    void Function(CaptureEnvelope envelope)? onCapture,
  }) async {
    if (_hasProcessedPreviousSessionExitState) {
      await _sessionStateStore.writeCleanShutdown(false);
      return;
    }

    final bool? priorCleanShutdown =
        await _sessionStateStore.readCleanShutdown();
    final int? priorLastCheckpointTimestampMs =
        await _sessionStateStore.readLastCheckpointTimestampMs();
    await _sessionStateStore.writeCleanShutdown(false);
    _hasProcessedPreviousSessionExitState = true;

    if (priorCleanShutdown == true ||
        priorLastCheckpointTimestampMs == null ||
        priorLastCheckpointTimestampMs < 0) {
      return;
    }

    _emitPreviousSessionUncleanExitCapture(
      priorLastCheckpointTimestampMs: priorLastCheckpointTimestampMs,
      onCapture: onCapture,
    );
  }

  void _emitPreviousSessionUncleanExitCapture({
    required int priorLastCheckpointTimestampMs,
    void Function(CaptureEnvelope envelope)? onCapture,
  }) {
    final Map<String, Object?>? observed = _buildUncleanExitObserved(
      priorLastCheckpointTimestampMs: priorLastCheckpointTimestampMs,
    );
    if (observed == null) {
      return;
    }

    if (_hasEmittedPreviousSessionUncleanExitCapture) {
      return;
    }
    _hasEmittedPreviousSessionUncleanExitCapture = true;

    final CaptureEnvelope envelope = _captureWithTrigger(
      triggerType: _previousSessionUncleanExitTriggerType,
      observed: observed,
      triggerAttributes: const <String, Object?>{
        "failure_kind": _previousSessionUncleanExitTriggerType,
      },
    );
    onCapture?.call(envelope);
  }

  Map<String, Object?>? _buildUncleanExitObserved({
    required int priorLastCheckpointTimestampMs,
  }) {
    if (priorLastCheckpointTimestampMs < 0) {
      return null;
    }

    final int nowUtcMs = DateTime.now().millisecondsSinceEpoch;
    final int ageMs = nowUtcMs - priorLastCheckpointTimestampMs;
    if (ageMs < 0) {
      return null;
    }
    return <String, Object?>{_lastCheckpointAgeMsKey: ageMs};
  }

  static String _resolveSanitizedPath({
    String? path,
    String? url,
    String? sanitizedPath,
  }) {
    final String? explicitSanitized = _normalizeNullableString(sanitizedPath);
    if (explicitSanitized != null) {
      return sanitizeNetworkPath(explicitSanitized);
    }

    final String? rawPath = _normalizeNullableString(path);
    final String? rawUrl = _normalizeNullableString(url);
    final String? source = rawPath ?? rawUrl;
    if (source == null) {
      throw ArgumentError(
        "One of `sanitizedPath`, `path`, or `url` must be provided.",
      );
    }
    return sanitizeNetworkPath(source);
  }

  static void _requireNonNegativeTimestamp(int tMonoMs) {
    if (tMonoMs < 0) {
      throw ArgumentError.value(tMonoMs, "tMonoMs", "must be >= 0");
    }
  }

  static void _requireNonEmptyString(String value, String name) {
    if (value.isEmpty) {
      throw ArgumentError.value(value, name, "must not be empty");
    }
  }

  static String _normalizeRequiredString(String value, String name) {
    final String normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, name, "must not be empty");
    }
    return normalized;
  }

  static String? _normalizeNullableString(String? value) {
    if (value == null) {
      return null;
    }
    final String normalized = value.trim();
    if (normalized.isEmpty) {
      return null;
    }
    return normalized;
  }

  static String _truncateString(String value, int maxLength) {
    if (value.length <= maxLength) {
      return value;
    }
    return value.substring(0, maxLength);
  }

  String? _resolveCurrentAppVersion({String? appVersion}) {
    if (appVersion != null) {
      return _normalizeRequiredString(appVersion, "appVersion");
    }
    final String? configuredAppVersion = config.appVersion;
    if (configuredAppVersion == null) {
      return null;
    }
    return _normalizeRequiredString(configuredAppVersion, "config.appVersion");
  }

  Future<RuntimeConditionsSnapshot> _resolveRuntimeConditions() async {
    try {
      final RuntimeConditionsSnapshot snapshot =
          await _runtimeConditionsProvider.resolve();
      final List<String> missingFields = <String>[
        if (snapshot.deviceModel == null) "device_model",
        if (snapshot.osVersion == null) "os_version",
        if (snapshot.networkType == null) "network_type",
      ];
      if (missingFields.isNotEmpty) {
        config.logger(
          SdkLogEntry(
            level: SdkLogLevel.warning,
            code: SdkLogCodes.runtimeConditionsMissing,
            message: "Runtime conditions resolved with missing fields.",
            metadata: <String, Object?>{
              "missing_fields": List<String>.unmodifiable(missingFields),
            },
          ),
        );
      }
      return snapshot;
    } on Exception catch (error, stackTrace) {
      config.logger(
        SdkLogEntry(
          level: SdkLogLevel.warning,
          code: SdkLogCodes.runtimeConditionsFallback,
          message: "Runtime conditions fell back to unknown.",
          metadata: <String, Object?>{
            "error_type": error.runtimeType.toString(),
            "fallback": "unknown",
          },
          stackTrace: stackTrace,
        ),
      );
      rethrow;
    }
  }

  Future<StateSnapshot> _resolveStateSnapshot() async {
    try {
      return await _stateSnapshotProvider.capture(
        maxStateKeys: config.maxStateKeys,
        maxStateBytes: config.maxStateBytes,
        maxStringLen: config.maxStringLen,
        hashSalt: config.stateHashSalt,
      );
    } on Exception catch (error, stackTrace) {
      config.logger(
        SdkLogEntry(
          level: SdkLogLevel.warning,
          code: SdkLogCodes.stateSnapshotFallback,
          message: "State snapshot fell back to an empty snapshot.",
          metadata: <String, Object?>{
            "error_type": error.runtimeType.toString(),
            "fallback": "empty_snapshot",
          },
          stackTrace: stackTrace,
        ),
      );
      rethrow;
    }
  }

  Future<void> _persistPendingPack(
    LocalPackRepository localPackRepository,
    PackBuildResult result,
  ) async {
    try {
      await localPackRepository.savePending(result);
    } catch (error, stackTrace) {
      final Object? captureId = result.payload["capture_id"];
      config.logger(
        SdkLogEntry(
          level: SdkLogLevel.error,
          code: SdkLogCodes.localPersistenceFailed,
          message: "Local pack persistence failed.",
          metadata: <String, Object?>{
            if (captureId is String && captureId.isNotEmpty)
              "capture_id": captureId,
            "error_type": error.runtimeType.toString(),
            "stage": "save_pending",
          },
          stackTrace: stackTrace,
        ),
      );
      rethrow;
    }
  }
}

/// Restore handle returned by [RevclustSdk.installUnhandledExceptionHooks].
class UnhandledExceptionHooks {
  UnhandledExceptionHooks._({required void Function() restoreHandlers})
      : _restoreHandlers = restoreHandlers;

  final void Function() _restoreHandlers;
  bool _restored = false;

  /// Restores previously installed global handlers exactly once.
  void restore() {
    if (_restored) {
      return;
    }
    _restored = true;
    _restoreHandlers();
  }

  /// Alias for [restore].
  void uninstall() {
    restore();
  }
}
