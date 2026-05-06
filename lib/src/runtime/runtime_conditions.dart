import "package:connectivity_plus/connectivity_plus.dart";
import "package:device_info_plus/device_info_plus.dart";
import "package:flutter/foundation.dart";

typedef DeviceConditionsReader = Future<RuntimeConditionsSnapshot> Function();
typedef ConnectivityResultsReader = Future<List<ConnectivityResult>> Function();

/// Snapshot of best-effort runtime conditions used by FR2 pack fields.
class RuntimeConditionsSnapshot {
  const RuntimeConditionsSnapshot({
    this.deviceModel,
    this.osVersion,
    this.networkType,
  });

  static const RuntimeConditionsSnapshot unknown = RuntimeConditionsSnapshot();

  final String? deviceModel;
  final String? osVersion;
  final String? networkType;
}

/// Capture-time handle for runtime conditions that may resolve asynchronously.
class CapturedRuntimeConditions {
  CapturedRuntimeConditions._(this._snapshotFuture);

  factory CapturedRuntimeConditions.snapshot(
    RuntimeConditionsSnapshot snapshot,
  ) {
    return CapturedRuntimeConditions._(
      Future<RuntimeConditionsSnapshot>.value(snapshot),
    );
  }

  factory CapturedRuntimeConditions.capture(
    Future<RuntimeConditionsSnapshot> Function() captureSnapshot,
  ) {
    final Future<RuntimeConditionsSnapshot> snapshotFuture =
        Future<RuntimeConditionsSnapshot>.sync(() async {
      try {
        return await captureSnapshot();
      } on Exception {
        return RuntimeConditionsSnapshot.unknown;
      }
    });
    return CapturedRuntimeConditions._(snapshotFuture);
  }

  static final CapturedRuntimeConditions unknown =
      CapturedRuntimeConditions.snapshot(RuntimeConditionsSnapshot.unknown);

  final Future<RuntimeConditionsSnapshot> _snapshotFuture;

  Future<RuntimeConditionsSnapshot> resolve() {
    return _snapshotFuture;
  }
}

/// Abstraction for runtime/platform condition capture.
abstract class RuntimeConditionsProvider {
  Future<RuntimeConditionsSnapshot> resolve();
}

/// Default Flutter-backed provider for device, OS, and connectivity metadata.
class FlutterRuntimeConditionsProvider implements RuntimeConditionsProvider {
  FlutterRuntimeConditionsProvider({
    DeviceInfoPlugin? deviceInfoPlugin,
    Connectivity? connectivity,
    DeviceConditionsReader? deviceConditionsReader,
    ConnectivityResultsReader? connectivityResultsReader,
  })  : _deviceInfoPlugin = deviceInfoPlugin ?? DeviceInfoPlugin(),
        _connectivity = connectivity ?? Connectivity(),
        _deviceConditionsReader = deviceConditionsReader,
        _connectivityResultsReader = connectivityResultsReader;

  final DeviceInfoPlugin _deviceInfoPlugin;
  final Connectivity _connectivity;
  final DeviceConditionsReader? _deviceConditionsReader;
  final ConnectivityResultsReader? _connectivityResultsReader;

  @override
  Future<RuntimeConditionsSnapshot> resolve() async {
    final RuntimeConditionsSnapshot deviceConditions =
        await _resolveDeviceConditions();
    final String? networkType = await _resolveNetworkType();

    return RuntimeConditionsSnapshot(
      deviceModel: deviceConditions.deviceModel,
      osVersion: deviceConditions.osVersion,
      networkType: networkType,
    );
  }

  Future<RuntimeConditionsSnapshot> _resolveDeviceConditions() async {
    try {
      final DeviceConditionsReader? reader = _deviceConditionsReader;
      if (reader != null) {
        return await reader();
      }

      if (kIsWeb) {
        final WebBrowserInfo info = await _deviceInfoPlugin.webBrowserInfo;
        return RuntimeConditionsSnapshot(
          deviceModel: _joinNonEmpty(<String?>[
            _enumName(info.browserName),
            info.platform,
          ]),
          osVersion: _normalizeOptionalString(info.userAgent),
        );
      }

      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final AndroidDeviceInfo info = await _deviceInfoPlugin.androidInfo;
          return RuntimeConditionsSnapshot(
            deviceModel: _normalizeOptionalString(info.model),
            osVersion: _joinNonEmpty(<String?>[
              "Android",
              info.version.release,
            ]),
          );
        case TargetPlatform.iOS:
          final IosDeviceInfo info = await _deviceInfoPlugin.iosInfo;
          return RuntimeConditionsSnapshot(
            deviceModel: _normalizeOptionalString(info.utsname.machine),
            osVersion: _joinNonEmpty(<String?>[
              info.systemName,
              info.systemVersion,
            ]),
          );
        case TargetPlatform.macOS:
          final MacOsDeviceInfo info = await _deviceInfoPlugin.macOsInfo;
          return RuntimeConditionsSnapshot(
            deviceModel: _normalizeOptionalString(
              info.data["model"] as String?,
            ),
            osVersion: _joinNonEmpty(<String?>[
              "macOS",
              info.data["osRelease"] as String?,
            ]),
          );
        case TargetPlatform.linux:
          final LinuxDeviceInfo info = await _deviceInfoPlugin.linuxInfo;
          return RuntimeConditionsSnapshot(
            deviceModel: _firstNonEmpty(<String?>[
              info.data["prettyName"] as String?,
              info.data["name"] as String?,
            ]),
            osVersion: _joinNonEmpty(<String?>[
              info.data["name"] as String?,
              info.data["version"] as String?,
            ]),
          );
        case TargetPlatform.windows:
          final WindowsDeviceInfo info = await _deviceInfoPlugin.windowsInfo;
          return RuntimeConditionsSnapshot(
            deviceModel: _normalizeOptionalString(
              info.data["computerName"] as String?,
            ),
            osVersion: _joinNonEmpty(<String?>[
              "Windows",
              info.data["displayVersion"] as String?,
            ]),
          );
        case TargetPlatform.fuchsia:
          return RuntimeConditionsSnapshot.unknown;
      }
    } on FlutterError {
      return RuntimeConditionsSnapshot.unknown;
    } on Exception {
      return RuntimeConditionsSnapshot.unknown;
    }
  }

  Future<String?> _resolveNetworkType() async {
    try {
      final ConnectivityResultsReader? reader = _connectivityResultsReader;
      final List<ConnectivityResult> results = reader != null
          ? await reader()
          : await _connectivity.checkConnectivity();
      return _mapConnectivityResults(results);
    } on FlutterError {
      return null;
    } on Exception {
      return null;
    }
  }

  static String? _mapConnectivityResults(List<ConnectivityResult> results) {
    final Set<ConnectivityResult> distinct = results.toSet();
    if (distinct.isEmpty) {
      return null;
    }
    if (distinct.contains(ConnectivityResult.wifi) ||
        distinct.contains(ConnectivityResult.ethernet)) {
      return "wifi";
    }
    if (distinct.contains(ConnectivityResult.mobile)) {
      return "cellular";
    }
    if (distinct.length == 1 && distinct.contains(ConnectivityResult.none)) {
      return "offline";
    }
    return null;
  }

  static String? _firstNonEmpty(List<String?> values) {
    for (final String? value in values) {
      final String? normalized = _normalizeOptionalString(value);
      if (normalized != null) {
        return normalized;
      }
    }
    return null;
  }

  static String? _joinNonEmpty(List<String?> values) {
    final List<String> normalized = values
        .map(_normalizeOptionalString)
        .whereType<String>()
        .toList(growable: false);
    if (normalized.isEmpty) {
      return null;
    }
    return normalized.join(" ");
  }

  static String? _normalizeOptionalString(String? value) {
    if (value == null) {
      return null;
    }
    final String normalized = value.trim();
    if (normalized.isEmpty) {
      return null;
    }
    return normalized;
  }

  static String? _enumName(Object? value) {
    if (value is Enum) {
      return value.name;
    }
    return value?.toString();
  }
}
