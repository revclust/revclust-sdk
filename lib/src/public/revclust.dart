import "dart:async";
import "dart:collection";

import "package:dio/dio.dart";

import "../persistence/local_pack_repository.dart";
import "../state/state_snapshot.dart";
import "revclust_bootstrap.dart";
import "revclust_bootstrap_origin.dart";
import "revclust_capture_outcome.dart";
import "revclust_config.dart";
import "revclust_diagnostics.dart";
import "revclust_invariant_failure.dart";
import "revclust_local_capture.dart";
import "revclust_owned_upload.dart";
import "revclust_status.dart";
import "revclust_upload_event.dart";
import "revclust_upload_snapshot.dart";

export "revclust_bootstrap.dart";

/// Partner-facing app-scoped Revclust facade.
abstract interface class Revclust {
  /// Starts public Revclust bootstrap and returns the app-scoped client.
  static Future<Revclust> initialize(RevclustConfig config) =>
      _RevclustFacadeRuntime.instance.initialize(config);

  /// Current service-health state for the hosted-first facade.
  RevclustStatus get status;

  /// Current best-known upload queue or upload state.
  RevclustUploadSnapshot get uploadSnapshot;

  /// Current privacy-safe diagnostics snapshot.
  RevclustDiagnostics get diagnostics;

  /// Broadcast stream of later upload lifecycle events.
  Stream<RevclustUploadEvent> get uploadEvents;

  /// Captures one app-owned invariant failure as factual evidence.
  Future<RevclustCaptureOutcome> captureInvariantFailure(
    RevclustInvariantFailure failure,
  );

  /// Records a reviewed app-owned UI breadcrumb for future captures.
  ///
  /// This is best-effort and does not throw for invalid breadcrumb input.
  void recordUiIntent({
    required String name,
    Map<String, Object?> attributes = const <String, Object?>{},
  });

  /// Records a reviewed app-owned screen transition breadcrumb.
  ///
  /// This is best-effort and does not throw for invalid breadcrumb input.
  void recordScreenTransition({
    required String fromScreen,
    required String toScreen,
    Map<String, Object?> attributes = const <String, Object?>{},
  });

  /// Installs the MVP Dio capture adapter for the host app.
  void enableDioCapture(Dio dio);

  /// Registers a bounded app-state provider for future captures.
  void setStateSnapshotProvider(RevclustStateSnapshotProvider provider);

  /// Installs unhandled exception capture hooks for the host app.
  void enableUnhandledExceptionCapture();
}

/// Synchronous state snapshot provider used by the public facade.
typedef RevclustStateSnapshotProvider = RevclustStateSnapshot Function();

/// Small partner-facing state snapshot payload.
///
/// This keeps state capture product-shaped instead of exposing internal
/// envelope or pack model types in the default integration path.
final class RevclustStateSnapshot {
  const RevclustStateSnapshot({
    this.appState = const <String, Object?>{},
    this.dataState = const <String, Object?>{},
  });

  /// Small app-orientation state that is safe to attach to a capture.
  final Map<String, Object?> appState;

  /// Small data-oriented state that is safe to attach to a capture.
  final Map<String, Object?> dataState;
}

/// Explicit lifecycle state for the public facade bootstrap/runtime.
sealed class RevclustFacadeLifecycleState {
  const RevclustFacadeLifecycleState({
    this.config,
    this.message,
  });

  final RevclustConfig? config;
  final String? message;

  RevclustStatus get status;
}

/// No app-scoped facade has been initialized yet.
final class RevclustFacadeDisabled extends RevclustFacadeLifecycleState {
  const RevclustFacadeDisabled({
    super.message,
  });

  @override
  RevclustStatus get status => RevclustStatus.disabled;
}

/// Bootstrap has started but has not resolved yet.
final class RevclustFacadeInitializing extends RevclustFacadeLifecycleState {
  const RevclustFacadeInitializing({
    required RevclustConfig config,
    super.message,
  }) : super(config: config);

  @override
  RevclustStatus get status => RevclustStatus.initializing;
}

/// Provisional bootstrap succeeded and the facade is healthy.
final class RevclustFacadeReady extends RevclustFacadeLifecycleState {
  const RevclustFacadeReady({
    required RevclustConfig config,
    super.message,
  }) : super(config: config);

  @override
  RevclustStatus get status => RevclustStatus.ready;
}

/// Bootstrap could not be reached or completed successfully.
final class RevclustFacadeBootstrapUnavailable
    extends RevclustFacadeLifecycleState {
  const RevclustFacadeBootstrapUnavailable({
    required RevclustConfig config,
    super.message,
  }) : super(config: config);

  @override
  RevclustStatus get status => RevclustStatus.degraded;
}

/// Local capture setup failed before the facade could become usable.
final class RevclustFacadeLocalCaptureUnavailable
    extends RevclustFacadeLifecycleState {
  const RevclustFacadeLocalCaptureUnavailable({
    required RevclustConfig config,
    super.message,
  }) : super(config: config);

  @override
  RevclustStatus get status => RevclustStatus.degraded;
}

/// Config is clearly invalid for this provisional bootstrap model.
final class RevclustFacadeMisconfigured extends RevclustFacadeLifecycleState {
  const RevclustFacadeMisconfigured({
    required RevclustConfig config,
    super.message,
  }) : super(config: config);

  @override
  RevclustStatus get status => RevclustStatus.misconfigured;
}

/// Config looks structurally valid but is not provisioned.
final class RevclustFacadeNotProvisioned extends RevclustFacadeLifecycleState {
  const RevclustFacadeNotProvisioned({
    required RevclustConfig config,
    super.message,
  }) : super(config: config);

  @override
  RevclustStatus get status => RevclustStatus.notProvisioned;
}

/// Config is valid but upload authorization is not currently usable.
final class RevclustFacadeUploadBlocked extends RevclustFacadeLifecycleState {
  const RevclustFacadeUploadBlocked({
    required RevclustConfig config,
    super.message,
  }) : super(config: config);

  @override
  RevclustStatus get status => RevclustStatus.uploadBlocked;
}

/// Debug snapshot of the current facade internals for test coverage.
final class RevclustFacadeDebugSnapshot {
  const RevclustFacadeDebugSnapshot({
    required this.lifecycleState,
    required this.registeredDioCount,
    required this.hasStateSnapshotProvider,
    required this.unhandledExceptionCaptureEnabled,
  });

  final RevclustFacadeLifecycleState lifecycleState;
  final int registeredDioCount;
  final bool hasStateSnapshotProvider;
  final bool unhandledExceptionCaptureEnabled;
}

/// Test-only controls for the app-scoped facade singleton.
final class RevclustFacadeTestSupport {
  static RevclustFacadeLifecycleState get lifecycleState =>
      _RevclustFacadeRuntime.instance.lifecycleState;

  static Revclust? get currentFacade =>
      _RevclustFacadeRuntime.instance.currentFacade;

  static RevclustBootstrapProbe get bootstrapProbe =>
      _RevclustFacadeRuntime.instance._bootstrapProbe;

  static set bootstrapProbe(RevclustBootstrapProbe probe) {
    _RevclustFacadeRuntime.instance._bootstrapProbe = probe;
  }

  static RevclustOwnedUploadTransport get uploadTransport =>
      _RevclustFacadeRuntime.instance._uploadTransport;

  static set uploadTransport(RevclustOwnedUploadTransport transport) {
    _RevclustFacadeRuntime.instance._uploadTransport = transport;
  }

  static RevclustOwnedUploadRetryPolicy get uploadRetryPolicy =>
      _RevclustFacadeRuntime.instance._uploadRetryPolicy;

  static set uploadRetryPolicy(RevclustOwnedUploadRetryPolicy policy) {
    _RevclustFacadeRuntime.instance._uploadRetryPolicy = policy;
  }

  static DateTime Function() get utcNow =>
      _RevclustFacadeRuntime.instance._utcNow;

  static set utcNow(DateTime Function() value) {
    _RevclustFacadeRuntime.instance._utcNow = value;
  }

  static RevclustFacadeLocalCaptureFactory get localCaptureFactory =>
      _RevclustFacadeRuntime.instance._localCaptureFactory;

  static set localCaptureFactory(RevclustFacadeLocalCaptureFactory factory) {
    _RevclustFacadeRuntime.instance._localCaptureFactory = factory;
  }

  static String localStorageDatabaseFileName(RevclustConfig config) =>
      resolveRevclustFacadeLocalStorageScope(config).databaseFileName;

  static String localStorageKey(RevclustConfig config) =>
      resolveRevclustFacadeLocalStorageScope(config).storageKey;

  static RevclustFacadeDebugSnapshot snapshot(Revclust facade) =>
      _RevclustFacadeRuntime.instance.snapshot(facade);

  static Future<void> refreshBootstrap(Revclust facade) =>
      _RevclustFacadeRuntime.instance._requireFacade(facade).refreshBootstrap();

  static void reset() => _RevclustFacadeRuntime.instance.debugReset();
}

final class _RevclustFacadeRuntime {
  _RevclustFacadeRuntime._();

  static final _RevclustFacadeRuntime instance = _RevclustFacadeRuntime._();

  RevclustBootstrapProbe _bootstrapProbe = HttpRevclustBootstrapProbe();
  RevclustOwnedUploadTransport _uploadTransport =
      HttpRevclustOwnedUploadTransport();
  RevclustOwnedUploadRetryPolicy _uploadRetryPolicy =
      const RevclustOwnedUploadRetryPolicy();
  DateTime Function() _utcNow = () => DateTime.now().toUtc();
  RevclustFacadeLocalCaptureFactory _localCaptureFactory =
      const DefaultRevclustFacadeLocalCaptureFactory();
  RevclustFacadeLifecycleState _lifecycleState = const RevclustFacadeDisabled();
  RevclustConfig? _activeConfig;
  _RevclustFacadeImpl? _facade;
  Future<Revclust>? _initializationFuture;
  int _generation = 0;

  RevclustFacadeLifecycleState get lifecycleState => _lifecycleState;
  Revclust? get currentFacade => _facade;

  Future<Revclust> initialize(RevclustConfig config) {
    final StateError? conflict = _conflictError(config);
    if (conflict != null) {
      return Future<Revclust>.error(conflict);
    }

    final Future<Revclust>? inFlightInitialization = _initializationFuture;
    if (inFlightInitialization != null) {
      return inFlightInitialization;
    }

    final _RevclustFacadeImpl? existingFacade = _facade;
    if (existingFacade != null) {
      return Future<Revclust>.value(existingFacade);
    }

    final _RevclustFacadeImpl facade = _RevclustFacadeImpl._(
      config: config,
      bootstrapProbe: _bootstrapProbe,
      localCaptureFactory: _localCaptureFactory,
      uploadTransport: _uploadTransport,
      uploadRetryPolicy: _uploadRetryPolicy,
      utcNow: _utcNow,
      onLifecycleChanged: _onLifecycleChanged,
    );
    final int generation = ++_generation;
    _facade = facade;
    _activeConfig = config;
    _onLifecycleChanged(facade.lifecycleState);

    final Future<Revclust> newInitializationFuture =
        _initializeFacade(facade, generation);
    _initializationFuture = newInitializationFuture;
    return newInitializationFuture;
  }

  RevclustFacadeDebugSnapshot snapshot(Revclust facade) {
    final _RevclustFacadeImpl facadeImpl = _requireFacade(facade);
    return RevclustFacadeDebugSnapshot(
      lifecycleState: facadeImpl.lifecycleState,
      registeredDioCount: facadeImpl.registeredDioCount,
      hasStateSnapshotProvider: facadeImpl.hasStateSnapshotProvider,
      unhandledExceptionCaptureEnabled:
          facadeImpl.unhandledExceptionCaptureEnabled,
    );
  }

  _RevclustFacadeImpl _requireFacade(Revclust facade) {
    if (facade is! _RevclustFacadeImpl) {
      throw ArgumentError.value(
        facade,
        "facade",
        "must come from Revclust.initialize(...)",
      );
    }
    return facade;
  }

  void debugReset() {
    _generation++;
    _initializationFuture = null;
    _activeConfig = null;
    _lifecycleState = const RevclustFacadeDisabled();
    _facade?._dispose();
    _facade = null;
    _bootstrapProbe = HttpRevclustBootstrapProbe();
    _uploadTransport = HttpRevclustOwnedUploadTransport();
    _uploadRetryPolicy = const RevclustOwnedUploadRetryPolicy();
    _utcNow = () => DateTime.now().toUtc();
    _localCaptureFactory = const DefaultRevclustFacadeLocalCaptureFactory();
  }

  Future<Revclust> _initializeFacade(
    _RevclustFacadeImpl facade,
    int generation,
  ) async {
    try {
      await facade.initializeLocalCapture();
    } catch (error, stackTrace) {
      await _failInitialization(
        facade,
        generation,
        RevclustFacadeLocalCaptureUnavailable(
          config: facade.config,
          message: "Local capture initialization failed: $error",
        ),
      );
      Error.throwWithStackTrace(
        StateError(
          "Revclust local capture initialization failed for "
          "${_describeConfig(facade.config)}: $error",
        ),
        stackTrace,
      );
    }

    try {
      await facade.refreshBootstrap();
    } catch (error) {
      await facade.applyLifecycleState(
        RevclustFacadeBootstrapUnavailable(
          config: facade.config,
          message: "Bootstrap assessment failed unexpectedly.",
        ),
      );
      return _finishInitialization(facade, generation);
    }
    return _finishInitialization(facade, generation);
  }

  Future<void> _failInitialization(
    _RevclustFacadeImpl facade,
    int generation,
    RevclustFacadeLifecycleState state,
  ) async {
    if (_generation != generation || !identical(_facade, facade)) {
      return;
    }
    await facade.applyLifecycleState(state);
    _initializationFuture = null;
    _activeConfig = null;
    _facade = null;
    facade._dispose();
  }

  Future<Revclust> _finishInitialization(
    _RevclustFacadeImpl facade,
    int generation,
  ) async {
    if (_generation == generation && identical(_facade, facade)) {
      _initializationFuture = null;
    }
    return facade;
  }

  void _onLifecycleChanged(RevclustFacadeLifecycleState state) {
    _lifecycleState = state;
  }

  StateError? _conflictError(RevclustConfig config) {
    final RevclustConfig? activeConfig = _activeConfig;
    if (activeConfig == null || _sameConfig(activeConfig, config)) {
      return null;
    }
    return StateError(
      "Revclust is already initialized for ${_describeConfig(activeConfig)}; "
      "conflicting initialize(...) received ${_describeConfig(config)}.",
    );
  }

  bool _sameConfig(RevclustConfig left, RevclustConfig right) => left == right;

  String _describeConfig(RevclustConfig config) =>
      'projectKey "${_maskProjectKey(config.projectKey)}"';

  String _maskProjectKey(String value) {
    if (value.length <= 12) {
      return "rpk_...";
    }
    return "${value.substring(0, 8)}...${value.substring(value.length - 4)}";
  }
}

final class _RevclustFacadeImpl
    implements Revclust, RevclustDrainBootstrapDelegate {
  _RevclustFacadeImpl._({
    required this.config,
    required RevclustBootstrapProbe bootstrapProbe,
    required RevclustFacadeLocalCaptureFactory localCaptureFactory,
    required RevclustOwnedUploadTransport uploadTransport,
    required RevclustOwnedUploadRetryPolicy uploadRetryPolicy,
    required DateTime Function() utcNow,
    required void Function(RevclustFacadeLifecycleState state)
        onLifecycleChanged,
  })  : _onLifecycleChanged = onLifecycleChanged,
        _bootstrapProbe = bootstrapProbe,
        _localCaptureFactory = localCaptureFactory,
        _uploadTransport = uploadTransport,
        _uploadRetryPolicy = uploadRetryPolicy,
        _utcNow = utcNow,
        _uploadEventsController =
            StreamController<RevclustUploadEvent>.broadcast(sync: true),
        _lifecycleState = RevclustFacadeInitializing(config: config),
        _uploadSnapshot = RevclustUploadSnapshot(),
        _diagnostics = RevclustDiagnostics.notChecked(
          bootstrapOrigin: resolveInternalRevclustBootstrapOrigin(config),
        );

  final RevclustConfig config;
  final void Function(RevclustFacadeLifecycleState state) _onLifecycleChanged;
  final RevclustBootstrapProbe _bootstrapProbe;
  final RevclustFacadeLocalCaptureFactory _localCaptureFactory;
  final RevclustOwnedUploadTransport _uploadTransport;
  final RevclustOwnedUploadRetryPolicy _uploadRetryPolicy;
  final DateTime Function() _utcNow;
  final StreamController<RevclustUploadEvent> _uploadEventsController;
  final Set<Dio> _registeredDioTargets = LinkedHashSet<Dio>.identity();
  RevclustStateSnapshotProvider? _stateSnapshotProvider;
  bool _unhandledExceptionCaptureEnabled = false;
  RevclustFacadeLifecycleState _lifecycleState;
  RevclustUploadSnapshot _uploadSnapshot;
  RevclustDiagnostics _diagnostics;
  RevclustBootstrapLease? _bootstrapLease;
  RevclustUploadErrorCode? _lastUploadErrorCode;
  RevclustFacadeLocalCapture? _localCapture;
  RevclustOwnedUploadCoordinator? _uploadCoordinator;
  Future<void>? _localCaptureInitializationFuture;
  Future<void> _breadcrumbRecordingFuture = Future<void>.value();
  bool _isDisposed = false;

  RevclustFacadeLifecycleState get lifecycleState => _lifecycleState;
  int get registeredDioCount => _registeredDioTargets.length;
  bool get hasStateSnapshotProvider => _stateSnapshotProvider != null;
  bool get unhandledExceptionCaptureEnabled =>
      _unhandledExceptionCaptureEnabled;

  @override
  RevclustStatus get status => _lifecycleState.status;

  @override
  RevclustUploadSnapshot get uploadSnapshot => _uploadSnapshot;

  @override
  RevclustDiagnostics get diagnostics => _diagnostics;

  @override
  Stream<RevclustUploadEvent> get uploadEvents =>
      _uploadEventsController.stream;

  @override
  Future<RevclustCaptureOutcome> captureInvariantFailure(
    RevclustInvariantFailure failure,
  ) async {
    if (!_isCaptureAllowed) {
      return _blockedCaptureOutcome(triggerType: "invariant failure capture");
    }
    await _breadcrumbRecordingFuture;
    final RevclustCaptureOutcome outcome =
        await (await _ensureLocalCapture()).captureInvariantFailure(failure);
    if (outcome is RevclustCaptureQueued) {
      await _refreshUploadSnapshotBestEffort();
      _uploadCoordinator?.requestDrain();
    }
    return outcome;
  }

  @override
  void recordUiIntent({
    required String name,
    Map<String, Object?> attributes = const <String, Object?>{},
  }) {
    if (_isDisposed) {
      return;
    }
    _enqueueBreadcrumb(
      (RevclustFacadeLocalCapture localCapture) =>
          localCapture.recordUiIntent(name: name, attributes: attributes),
    );
  }

  @override
  void recordScreenTransition({
    required String fromScreen,
    required String toScreen,
    Map<String, Object?> attributes = const <String, Object?>{},
  }) {
    if (_isDisposed) {
      return;
    }
    _enqueueBreadcrumb(
      (RevclustFacadeLocalCapture localCapture) =>
          localCapture.recordScreenTransition(
        fromScreen: fromScreen,
        toScreen: toScreen,
        attributes: attributes,
      ),
    );
  }

  @override
  void enableDioCapture(Dio dio) {
    _registeredDioTargets.add(dio);
    _localCapture?.enableDioCapture(dio);
  }

  @override
  void setStateSnapshotProvider(RevclustStateSnapshotProvider provider) {
    _stateSnapshotProvider = provider;
    _localCapture?.setStateSnapshotProvider(_stateSnapshotProviderAdapter);
  }

  @override
  void enableUnhandledExceptionCapture() {
    _unhandledExceptionCaptureEnabled = true;
  }

  Future<void> initializeLocalCapture() async {
    await _ensureLocalCapture();
    await _refreshUploadSnapshot();
  }

  Future<void> refreshBootstrap() async {
    final RevclustBootstrapAssessment assessment;
    try {
      assessment = await _bootstrapProbe.assess(config);
    } catch (error) {
      _diagnostics = RevclustDiagnostics(
        bootstrap: RevclustBootstrapDiagnostics(
          state: RevclustBootstrapDiagnosticState.unavailable,
          bootstrapOrigin: resolveInternalRevclustBootstrapOrigin(config),
          lastCheckedAt: _utcNow().toUtc(),
          errorCategory: "bootstrap_unavailable",
          retryable: true,
          message: "Bootstrap assessment failed unexpectedly.",
        ),
      );
      await applyLifecycleState(
        RevclustFacadeBootstrapUnavailable(
          config: config,
          message: "Bootstrap assessment failed unexpectedly.",
        ),
      );
      return;
    }

    final RevclustBootstrapAssessment normalizedAssessment =
        _normalizeBootstrapAssessment(assessment);
    _diagnostics = RevclustDiagnostics(
      bootstrap: normalizedAssessment.diagnostics ??
          _diagnosticsForAssessment(normalizedAssessment),
    );
    switch (normalizedAssessment.disposition) {
      case RevclustBootstrapDisposition.ready:
        final RevclustBootstrapLease lease = normalizedAssessment.lease!;
        _bootstrapLease = lease;
        _lastUploadErrorCode = null;
        await applyLifecycleState(
          RevclustFacadeReady(
            config: config,
            message: normalizedAssessment.message,
          ),
        );
        return;
      case RevclustBootstrapDisposition.bootstrapUnavailable:
        if (_hasUsableBootstrapLease) {
          await applyLifecycleState(
            RevclustFacadeReady(
              config: config,
              message: normalizedAssessment.message,
            ),
          );
          return;
        }
        _bootstrapLease = null;
        await applyLifecycleState(
          RevclustFacadeBootstrapUnavailable(
            config: config,
            message: normalizedAssessment.message ??
                "Bootstrap is unavailable; upload remains blocked.",
          ),
        );
        return;
      case RevclustBootstrapDisposition.misconfigured:
        _bootstrapLease = null;
        await applyLifecycleState(
          RevclustFacadeMisconfigured(
            config: config,
            message:
                normalizedAssessment.message ?? "Project key is misconfigured.",
          ),
        );
        return;
      case RevclustBootstrapDisposition.notProvisioned:
        _bootstrapLease = null;
        await applyLifecycleState(
          RevclustFacadeNotProvisioned(
            config: config,
            message: normalizedAssessment.message ??
                "Project key is not provisioned.",
          ),
        );
        return;
      case RevclustBootstrapDisposition.uploadBlocked:
        _bootstrapLease = null;
        await applyLifecycleState(
          RevclustFacadeUploadBlocked(
            config: config,
            message: normalizedAssessment.message ??
                "Upload authorization is not currently usable.",
          ),
        );
        return;
    }
  }

  Future<void> applyLifecycleState(RevclustFacadeLifecycleState state) async {
    _lifecycleState = state;
    _onLifecycleChanged(state);
    await _refreshUploadSnapshot();
    if (state is RevclustFacadeReady &&
        (_uploadSnapshot.pendingCount > 0 ||
            _uploadSnapshot.uploadingCount > 0)) {
      _uploadCoordinator?.requestDrain();
    }
  }

  void _dispose() {
    _isDisposed = true;
    _uploadCoordinator?.dispose();
    _uploadCoordinator = null;
    if (!_uploadEventsController.isClosed) {
      unawaited(_uploadEventsController.close());
    }
    final RevclustFacadeLocalCapture? localCapture = _localCapture;
    _localCapture = null;
    if (localCapture != null) {
      unawaited(localCapture.dispose());
    }
  }

  bool get _isCaptureAllowed => switch (_lifecycleState) {
        RevclustFacadeReady() ||
        RevclustFacadeBootstrapUnavailable() ||
        RevclustFacadeUploadBlocked() =>
          true,
        RevclustFacadeDisabled() ||
        RevclustFacadeInitializing() ||
        RevclustFacadeLocalCaptureUnavailable() ||
        RevclustFacadeMisconfigured() ||
        RevclustFacadeNotProvisioned() =>
          false,
      };

  void _enqueueBreadcrumb(
    void Function(RevclustFacadeLocalCapture localCapture) record,
  ) {
    if (!_isCaptureAllowed) {
      return;
    }

    _breadcrumbRecordingFuture = _breadcrumbRecordingFuture.then((_) async {
      if (_isDisposed || !_isCaptureAllowed) {
        return;
      }
      final RevclustFacadeLocalCapture localCapture =
          await _ensureLocalCapture();
      if (_isDisposed) {
        return;
      }
      record(localCapture);
    }).catchError((_) {
      // Reviewed breadcrumbs are best-effort and must not destabilize UI code.
    });
    unawaited(_breadcrumbRecordingFuture);
  }

  Future<RevclustFacadeLocalCapture> _ensureLocalCapture() async {
    final RevclustFacadeLocalCapture? existing = _localCapture;
    if (existing != null) {
      return existing;
    }

    final Future<void>? existingInitialization =
        _localCaptureInitializationFuture;
    if (existingInitialization != null) {
      await existingInitialization;
      final RevclustFacadeLocalCapture? initialized = _localCapture;
      if (initialized != null) {
        return initialized;
      }
      throw StateError("Revclust local capture runtime was not initialized.");
    }

    final Future<void> initialization = _createLocalCapture();
    _localCaptureInitializationFuture = initialization;
    await initialization;

    final RevclustFacadeLocalCapture? initialized = _localCapture;
    if (initialized == null) {
      throw StateError("Revclust local capture runtime was not initialized.");
    }
    return initialized;
  }

  Future<void> _createLocalCapture() async {
    RevclustFacadeLocalCapture? localCapture;
    try {
      localCapture = await _localCaptureFactory.create(config);
      if (_isDisposed) {
        await localCapture.dispose();
        return;
      }
      localCapture.setStateSnapshotProvider(_stateSnapshotProviderAdapter);
      for (final Dio dio in _registeredDioTargets) {
        localCapture.enableDioCapture(dio);
      }
      _localCapture = localCapture;
      _uploadCoordinator = RevclustOwnedUploadCoordinator(
        repository: localCapture.repository,
        bootstrapDelegate: this,
        transport: _uploadTransport,
        retryPolicy: _uploadRetryPolicy,
        utcNow: _utcNow,
        onQueueStateChanged: _refreshUploadSnapshot,
        onLastError: _setLastUploadError,
        onEvent: _emitUploadEvent,
      );
      localCapture = null;
    } catch (_) {
      final RevclustFacadeLocalCapture? createdLocalCapture = localCapture;
      if (createdLocalCapture != null) {
        await createdLocalCapture.dispose();
      }
      rethrow;
    } finally {
      _localCaptureInitializationFuture = null;
    }
  }

  Future<void> _refreshUploadSnapshot() async {
    final RevclustFacadeLocalCapture? localCapture = _localCapture;
    final LocalPackQueueState queueState = localCapture == null
        ? const LocalPackQueueState(
            pendingCount: 0,
            uploadingCount: 0,
          )
        : await localCapture.repository.describeQueue();
    _uploadSnapshot = _snapshotFor(
      _lifecycleState,
      pendingCount: queueState.pendingCount,
      uploadingCount: queueState.uploadingCount,
    );
  }

  void _setLastUploadError(RevclustUploadErrorCode? errorCode) {
    _lastUploadErrorCode = errorCode;
    _uploadSnapshot = _snapshotFor(
      _lifecycleState,
      pendingCount: _uploadSnapshot.pendingCount,
      uploadingCount: _uploadSnapshot.uploadingCount,
    );
  }

  Future<void> _refreshUploadSnapshotBestEffort() async {
    try {
      await _refreshUploadSnapshot();
    } on Object {
      // The queued outcome is already durable at this point; a stale snapshot
      // must not turn a successful queue into a thrown error.
    }
  }

  StateSnapshot Function()? get _stateSnapshotProviderAdapter {
    final RevclustStateSnapshotProvider? provider = _stateSnapshotProvider;
    if (provider == null) {
      return null;
    }
    return () {
      final RevclustStateSnapshot snapshot = provider();
      return StateSnapshot(
        appState: Map<String, Object?>.from(snapshot.appState),
        dataState: Map<String, Object?>.from(snapshot.dataState),
      );
    };
  }

  bool get _hasUsableBootstrapLease {
    final RevclustBootstrapLease? lease = _bootstrapLease;
    return lease != null && lease.isUsableAt(_utcNow());
  }

  RevclustBootstrapAssessment _normalizeBootstrapAssessment(
    RevclustBootstrapAssessment assessment,
  ) {
    if (assessment.disposition == RevclustBootstrapDisposition.ready &&
        assessment.lease != null) {
      return assessment;
    }
    if (assessment.disposition == RevclustBootstrapDisposition.ready) {
      return const RevclustBootstrapAssessment.bootstrapUnavailable(
        message: "Hosted bootstrap returned an incomplete upload lease.",
      );
    }
    return assessment;
  }

  RevclustBootstrapDiagnostics _diagnosticsForAssessment(
    RevclustBootstrapAssessment assessment,
  ) {
    final RevclustBootstrapDiagnosticState state =
        switch (assessment.disposition) {
      RevclustBootstrapDisposition.ready =>
        RevclustBootstrapDiagnosticState.ready,
      RevclustBootstrapDisposition.bootstrapUnavailable =>
        RevclustBootstrapDiagnosticState.unavailable,
      RevclustBootstrapDisposition.misconfigured =>
        RevclustBootstrapDiagnosticState.misconfigured,
      RevclustBootstrapDisposition.notProvisioned =>
        RevclustBootstrapDiagnosticState.notProvisioned,
      RevclustBootstrapDisposition.uploadBlocked =>
        RevclustBootstrapDiagnosticState.uploadBlocked,
    };
    return RevclustBootstrapDiagnostics(
      state: state,
      bootstrapOrigin: resolveInternalRevclustBootstrapOrigin(config),
      lastCheckedAt: _utcNow().toUtc(),
      errorCategory: switch (assessment.disposition) {
        RevclustBootstrapDisposition.ready => null,
        RevclustBootstrapDisposition.bootstrapUnavailable =>
          "transport_unavailable",
        RevclustBootstrapDisposition.misconfigured => "invalid_project_key",
        RevclustBootstrapDisposition.notProvisioned =>
          "project_not_provisioned",
        RevclustBootstrapDisposition.uploadBlocked => "upload_auth_unavailable",
      },
      retryable: switch (assessment.disposition) {
        RevclustBootstrapDisposition.ready => false,
        RevclustBootstrapDisposition.bootstrapUnavailable => true,
        RevclustBootstrapDisposition.misconfigured => false,
        RevclustBootstrapDisposition.notProvisioned => false,
        RevclustBootstrapDisposition.uploadBlocked => true,
      },
      message: assessment.message,
    );
  }

  void _emitUploadEvent(RevclustUploadEvent event) {
    if (_uploadEventsController.isClosed) {
      return;
    }
    _uploadEventsController.add(event);
  }

  @override
  Future<RevclustDrainAccess> ensureReadyForDrain() async {
    if (_hasUsableBootstrapLease) {
      final RevclustBootstrapLease lease = _bootstrapLease!;
      if (_lifecycleState is! RevclustFacadeReady) {
        await applyLifecycleState(
          RevclustFacadeReady(
            config: config,
            message: _lifecycleState.message,
          ),
        );
      }
      return RevclustDrainAccessReady(lease);
    }

    await refreshBootstrap();
    if (_hasUsableBootstrapLease && _lifecycleState is RevclustFacadeReady) {
      return RevclustDrainAccessReady(_bootstrapLease!);
    }
    return _drainAccessForLifecycleState(_lifecycleState);
  }

  @override
  Future<RevclustDrainAccess> refreshAfterAuthFailure() async {
    _bootstrapLease = null;
    await refreshBootstrap();
    if (_hasUsableBootstrapLease && _lifecycleState is RevclustFacadeReady) {
      return RevclustDrainAccessReady(_bootstrapLease!);
    }
    return _drainAccessForLifecycleState(_lifecycleState);
  }

  RevclustDrainAccess _drainAccessForLifecycleState(
    RevclustFacadeLifecycleState state,
  ) {
    switch (state) {
      case RevclustFacadeReady():
        return const RevclustDrainAccessUnavailable(
          errorCode: RevclustUploadErrorCode.transportUnavailable,
          retryable: true,
          message: "Upload authorization is not currently usable.",
        );
      case RevclustFacadeBootstrapUnavailable():
        return RevclustDrainAccessUnavailable(
          errorCode: RevclustUploadErrorCode.transportUnavailable,
          retryable: true,
          message: state.message,
        );
      case RevclustFacadeUploadBlocked():
        return RevclustDrainAccessUnavailable(
          errorCode: RevclustUploadErrorCode.auth,
          retryable: true,
          message: state.message,
        );
      case RevclustFacadeMisconfigured():
      case RevclustFacadeNotProvisioned():
        return RevclustDrainAccessUnavailable(
          errorCode: RevclustUploadErrorCode.misconfiguration,
          retryable: false,
          message: state.message,
        );
      case RevclustFacadeLocalCaptureUnavailable():
        return RevclustDrainAccessUnavailable(
          errorCode: RevclustUploadErrorCode.internalError,
          retryable: false,
          message: state.message,
        );
      case RevclustFacadeDisabled():
      case RevclustFacadeInitializing():
        return const RevclustDrainAccessUnavailable(
          errorCode: RevclustUploadErrorCode.transportUnavailable,
          retryable: true,
          message: "Revclust is still initializing upload capability.",
        );
    }
  }

  RevclustCaptureBlocked _blockedCaptureOutcome({
    required String triggerType,
  }) {
    return RevclustCaptureBlocked(
      status: status,
      message: _captureBlockedMessage(triggerType: triggerType),
    );
  }

  String _captureBlockedMessage({
    required String triggerType,
  }) {
    final String actionName =
        triggerType[0].toUpperCase() + triggerType.substring(1);
    final String? lifecycleMessage = _lifecycleState.message;
    switch (_lifecycleState) {
      case RevclustFacadeDisabled():
        return "$actionName is unavailable before Revclust.initialize(...) "
            "has completed.";
      case RevclustFacadeInitializing():
        return "$actionName is blocked while Revclust is initializing.";
      case RevclustFacadeReady():
        return "$actionName is blocked unexpectedly while Revclust is ready.";
      case RevclustFacadeBootstrapUnavailable():
        return "$actionName is available while Revclust remains degraded.";
      case RevclustFacadeUploadBlocked():
        return "$actionName is available while upload remains blocked.";
      case RevclustFacadeLocalCaptureUnavailable():
        return lifecycleMessage ??
            "$actionName is blocked because local capture is unavailable.";
      case RevclustFacadeMisconfigured():
      case RevclustFacadeNotProvisioned():
        return lifecycleMessage ??
            "$actionName is blocked by the current Revclust service state.";
    }
  }

  RevclustUploadSnapshot _snapshotFor(
    RevclustFacadeLifecycleState state, {
    int pendingCount = 0,
    int uploadingCount = 0,
  }) {
    final RevclustUploadErrorCode? errorCode = switch (state) {
      RevclustFacadeBootstrapUnavailable() =>
        RevclustUploadErrorCode.transportUnavailable,
      RevclustFacadeUploadBlocked() => RevclustUploadErrorCode.auth,
      RevclustFacadeLocalCaptureUnavailable() =>
        RevclustUploadErrorCode.internalError,
      RevclustFacadeMisconfigured() ||
      RevclustFacadeNotProvisioned() =>
        RevclustUploadErrorCode.misconfiguration,
      RevclustFacadeDisabled() ||
      RevclustFacadeInitializing() ||
      RevclustFacadeReady() =>
        _lastUploadErrorCode,
    };
    return RevclustUploadSnapshot(
      pendingCount: pendingCount,
      uploadingCount: uploadingCount,
      lastErrorCode: errorCode,
    );
  }
}
