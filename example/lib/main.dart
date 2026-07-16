import "dart:async";

import "package:flutter/material.dart";
import "package:revclust_flutter_sdk/revclust_flutter.dart";

const String _sdkKey = String.fromEnvironment("REVCLUST_PROJECT_KEY");
const String _appVersion = String.fromEnvironment("REVCLUST_APP_VERSION");
const String _build = String.fromEnvironment("REVCLUST_BUILD");
const String _gitSha = String.fromEnvironment("REVCLUST_GIT_SHA");

void main() {
  runApp(const RevclustExampleApp());
}

class RevclustExampleApp extends StatelessWidget {
  const RevclustExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Revclust SDK Example",
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        splashFactory: InkRipple.splashFactory,
      ),
      home: const ExampleHomeScreen(),
    );
  }
}

class ExampleHomeScreen extends StatefulWidget {
  const ExampleHomeScreen({super.key});

  @override
  State<ExampleHomeScreen> createState() => _ExampleHomeScreenState();
}

class _ExampleHomeScreenState extends State<ExampleHomeScreen> {
  final List<String> _eventLog = <String>[];

  Revclust? _revclust;
  StreamSubscription<RevclustUploadEvent>? _uploadEventsSubscription;
  bool _initializing = false;
  bool _capturing = false;
  String? _activityMessage;
  String? _viewerUrl;

  bool get _hasBuildTimeConfig => _sdkKey.isNotEmpty;

  bool get _canInitialize =>
      _hasBuildTimeConfig && !_initializing && _revclust == null;

  bool get _canCapture => _revclust != null && !_initializing && !_capturing;

  @override
  void dispose() {
    _uploadEventsSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initializeSdk() async {
    if (!_hasBuildTimeConfig) {
      setState(() {
        _activityMessage = _missingConfigMessage;
      });
      return;
    }

    setState(() {
      _initializing = true;
      _activityMessage = null;
    });

    try {
      final Revclust revclust = await Revclust.initialize(
        RevclustConfig(
          projectKey: _sdkKey,
          appVersion: _optionalBuildValue(_appVersion),
          build: _optionalBuildValue(_build),
          gitSha: _optionalBuildValue(_gitSha),
        ),
      );

      revclust.setStateSnapshotProvider(
        () => RevclustStateSnapshot(
          appState: <String, Object?>{
            "screen": "example_home",
            "sdk_status": revclust.status.name,
          },
          dataState: const <String, Object?>{
            "sample_order_ref": "ord_ref_7d82b1",
            "sample_flow": "checkout_confirmation",
          },
        ),
      );

      await _uploadEventsSubscription?.cancel();
      _uploadEventsSubscription = revclust.uploadEvents.listen(
        _handleUploadEvent,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _revclust = revclust;
        _activityMessage = _initializedMessage(revclust.status);
        _eventLog.insert(
          0,
          "SDK initialized with status ${revclust.status.name}.",
        );
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _activityMessage =
            "SDK initialization failed. Check your Revclust configuration and setup.";
        _eventLog.insert(0, "SDK initialization failed.");
      });
    } finally {
      if (mounted) {
        setState(() {
          _initializing = false;
        });
      }
    }
  }

  String _initializedMessage(RevclustStatus status) {
    return switch (status) {
      RevclustStatus.ready =>
        "SDK is ready. Queue the sample incident to verify explicit capture and upload.",
      RevclustStatus.degraded || RevclustStatus.uploadBlocked =>
        "SDK initialized with status ${status.name}. Local capture can queue, but upload is not ready.",
      RevclustStatus.misconfigured || RevclustStatus.notProvisioned =>
        "SDK initialized with status ${status.name}. Check the SDK key and setup.",
      RevclustStatus.disabled || RevclustStatus.initializing =>
        "SDK initialized with status ${status.name}.",
    };
  }

  Future<void> _queueSampleIncident() async {
    final Revclust? revclust = _revclust;
    if (revclust == null) {
      return;
    }

    setState(() {
      _capturing = true;
      _activityMessage = null;
      _viewerUrl = null;
    });

    try {
      final RevclustCaptureOutcome
      outcome = await revclust.captureInvariantFailure(
        RevclustInvariantFailure(
          failureKind: "checkout_confirmation_mismatch",
          subject: RevclustSubject(kind: "order_ref", value: "ord_ref_7d82b1"),
          expected: const <String, Object?>{"order_status": "confirmed"},
          observed: const <String, Object?>{"order_status": "pending_review"},
        ),
      );

      if (!mounted) {
        return;
      }

      switch (outcome) {
        case RevclustCaptureQueued():
          setState(() {
            _activityMessage =
                "Sample incident queued as ${outcome.captureId}. Waiting for upload events.";
            _eventLog.insert(
              0,
              "Queued sample incident with capture ID ${outcome.captureId}.",
            );
          });
        case RevclustCaptureBlocked():
          setState(() {
            _activityMessage =
                outcome.message == null
                    ? "Sample incident was blocked with status ${outcome.status.name}."
                    : "Sample incident was blocked: ${outcome.message}";
          });
        case RevclustCaptureBuildFailed():
          setState(() {
            _activityMessage =
                outcome.message == null
                    ? "Sample incident could not be built."
                    : "Sample incident build failed: ${outcome.message}";
          });
        case RevclustCapturePersistenceFailed():
          setState(() {
            _activityMessage =
                outcome.message == null
                    ? "Sample incident could not be persisted locally."
                    : "Sample incident persistence failed: ${outcome.message}";
          });
      }
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _activityMessage =
            "Sample incident failed unexpectedly. Retry the capture or check the host logs.";
        _eventLog.insert(0, "Sample incident failed unexpectedly.");
      });
    } finally {
      if (mounted) {
        setState(() {
          _capturing = false;
        });
      }
    }
  }

  void _handleUploadEvent(RevclustUploadEvent event) {
    if (!mounted) {
      return;
    }

    switch (event) {
      case RevclustUploadStarted():
        setState(() {
          _eventLog.insert(0, "Upload started for capture ${event.captureId}.");
        });
      case RevclustUploadAccepted():
        setState(() {
          _viewerUrl = event.result.viewerUrl?.toString();
          _eventLog.insert(
            0,
            "Upload accepted for ${event.captureId} as pack ${event.result.packId}.",
          );
          _activityMessage =
              _viewerUrl == null
                  ? "Sample incident was accepted."
                  : "Sample incident was accepted. Open the viewer URL below.";
        });
      case RevclustUploadRejected():
        setState(() {
          _eventLog.insert(
            0,
            "Upload rejected for ${event.captureId} with code ${event.code.name}.",
          );
          _activityMessage =
              event.message == null
                  ? "Sample incident was rejected with code ${event.code.name}."
                  : "Sample incident was rejected: ${event.message}";
        });
      case RevclustTransportFailure():
        setState(() {
          _eventLog.insert(
            0,
            "Transport failure for ${event.captureId}${event.statusCode == null ? "" : " (HTTP ${event.statusCode})"}.",
          );
          _activityMessage =
              event.message == null
                  ? "Sample incident upload failed before acceptance."
                  : "Sample incident upload failed: ${event.message}";
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final Revclust? revclust = _revclust;
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text("Revclust SDK Example")),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: <Widget>[
          Text(
            "Initialize the SDK, register the state snapshot provider, then queue one sample incident to verify explicit capture on mobile.",
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          _Section(
            title: "Configuration",
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  "SDK key: ${_sdkKey.isEmpty ? "missing" : _maskSdkKey(_sdkKey)}",
                ),
                if (!_hasBuildTimeConfig) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(_missingConfigMessage),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          _Section(
            title: "SDK status",
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  "Current status: ${revclust?.status.name ?? RevclustStatus.disabled.name}",
                ),
                const SizedBox(height: 8),
                Text(
                  _activityMessage ??
                      "Initialize the SDK to begin the example flow.",
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: <Widget>[
              FilledButton(
                onPressed: _canInitialize ? _initializeSdk : null,
                child: Text(
                  _initializing ? "Initializing..." : "Initialize SDK",
                ),
              ),
              OutlinedButton(
                onPressed: _canCapture ? _queueSampleIncident : null,
                child: Text(
                  _capturing ? "Queueing..." : "Queue Sample Incident",
                ),
              ),
            ],
          ),
          if (_viewerUrl != null) ...<Widget>[
            const SizedBox(height: 16),
            _Section(title: "Viewer URL", child: SelectableText(_viewerUrl!)),
          ],
          const SizedBox(height: 16),
          _Section(
            title: "Upload event log",
            child:
                _eventLog.isEmpty
                    ? const Text(
                      "No upload events yet. Initialize the SDK and queue the sample incident first.",
                    )
                    : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _eventLog
                          .take(6)
                          .map(
                            (String event) => Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(event),
                            ),
                          )
                          .toList(growable: false),
                    ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

String get _missingConfigMessage =>
    "Provide REVCLUST_PROJECT_KEY via --dart-define to enable the example flow.";

String? _optionalBuildValue(String value) {
  if (value.isEmpty) {
    return null;
  }
  return value;
}

String _maskSdkKey(String value) {
  if (value.length <= 12) {
    return value;
  }

  return "${value.substring(0, 8)}...${value.substring(value.length - 4)}";
}
