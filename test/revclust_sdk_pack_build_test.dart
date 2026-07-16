import "dart:convert";

import "package:cryptography/cryptography.dart";
import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter_sdk/src/internal/revclust_internal.dart";
import "package:sqflite_common_ffi/sqflite_ffi.dart";

import "support/in_memory_key_store.dart";

void main() {
  group("RevclustSdk pack building", () {
    test("delayed build uses runtime conditions snapped at capture time",
        () async {
      final _SequencedRuntimeConditionsProvider provider =
          _SequencedRuntimeConditionsProvider(
        <RuntimeConditionsSnapshot>[
          const RuntimeConditionsSnapshot(
            deviceModel: "Pixel 9 Pro",
            osVersion: "Android 16",
            networkType: "wifi",
          ),
          const RuntimeConditionsSnapshot(
            deviceModel: "iPhone15,4",
            osVersion: "iOS 18.2",
            networkType: "cellular",
          ),
        ],
      );
      final RevclustSdk sdk = RevclustSdk(
        config: SdkConfig(
          appVersion: "2.4.0",
          build: "24001",
          gitSha: "ABCDEF1",
        ),
        monotonicClockMs: () => 5000,
        runtimeConditionsProvider: provider,
      );
      sdk.recordUiIntent(tMonoMs: 4500, name: "checkout.submit");
      final CaptureEnvelope envelope =
          sdk.captureNow(reason: "checkout mismatch");

      expect(provider.resolveCallCount, 1);

      final PackBuildResult result = await sdk.buildPack(
        captureEnvelope: envelope,
      );

      final Map<String, Object?> conditions = _asObjectMap(
        result.payload["conditions"],
      );
      expect(conditions["app_version"], "2.4.0");
      expect(conditions["build"], "24001");
      expect(conditions["git_sha"], "abcdef1");
      expect(conditions["device_model"], "Pixel 9 Pro");
      expect(conditions["os_version"], "Android 16");
      expect(conditions["network_type"], "wifi");
      expect(provider.resolveCallCount, 1);
    });

    test("provider failure at capture time still falls back safely", () async {
      final List<SdkLogEntry> logs = <SdkLogEntry>[];
      final RevclustSdk sdk = RevclustSdk(
        config: SdkConfig(
          appVersion: "2.4.0",
          build: "24001",
          logger: logs.add,
        ),
        monotonicClockMs: () => 5000,
        runtimeConditionsProvider: _ExceptionRuntimeConditionsProvider(),
      );
      final CaptureEnvelope envelope =
          sdk.captureNow(reason: "provider failure");

      final PackBuildResult result = await sdk.buildPack(
        captureEnvelope: envelope,
      );

      final Map<String, Object?> conditions = _asObjectMap(
        result.payload["conditions"],
      );
      expect(conditions["app_version"], "2.4.0");
      expect(conditions["build"], "24001");
      expect(conditions["device_model"], "unknown");
      expect(conditions["os_version"], "unknown");
      expect(conditions["network_type"], "unknown");
      expect(logs, hasLength(1));
      expect(logs.single.code, SdkLogCodes.runtimeConditionsFallback);
      expect(logs.single.level, SdkLogLevel.warning);
      expect(logs.single.metadata["fallback"], "unknown");
      expect(
        logs.single.metadata["error_type"] as String,
        contains("Exception"),
      );
    });

    test("provider errors are not normalized into unknown", () async {
      final RevclustSdk sdk = RevclustSdk(
        config: SdkConfig(appVersion: "2.4.0", build: "24001"),
        monotonicClockMs: () => 5000,
        runtimeConditionsProvider: _ErrorRuntimeConditionsProvider(),
      );
      final CaptureEnvelope envelope = sdk.captureNow(reason: "provider bug");

      expect(
        () => sdk.buildPack(captureEnvelope: envelope),
        throwsA(isA<StateError>()),
      );
    });

    test("state snapshot Exception falls back to empty snapshot", () async {
      final List<SdkLogEntry> logs = <SdkLogEntry>[];
      final RevclustSdk sdk = RevclustSdk(
        config: SdkConfig(
          appVersion: "2.4.0",
          build: "24001",
          logger: logs.add,
        ),
        monotonicClockMs: () => 5000,
        stateSnapshotProvider: _ExceptionStateSnapshotProvider(),
      );
      final CaptureEnvelope envelope =
          sdk.captureNow(reason: "state snapshot failure");

      final PackBuildResult result = await sdk.buildPack(
        captureEnvelope: envelope,
      );

      final Map<String, Object?> stateSnapshot = _asObjectMap(
        result.payload["state_snapshot"],
      );
      expect(_asObjectMap(stateSnapshot["app_state"]), isEmpty);
      expect(_asObjectMap(stateSnapshot["data_state"]), isEmpty);
      expect(
        logs.map((SdkLogEntry entry) => entry.code),
        contains(SdkLogCodes.stateSnapshotFallback),
      );
      final SdkLogEntry stateSnapshotFallbackLog = logs.firstWhere(
        (SdkLogEntry entry) => entry.code == SdkLogCodes.stateSnapshotFallback,
      );
      expect(stateSnapshotFallbackLog.level, SdkLogLevel.warning);
      expect(stateSnapshotFallbackLog.metadata["fallback"], "empty_snapshot");
      expect(
        stateSnapshotFallbackLog.metadata["error_type"] as String,
        contains("Exception"),
      );
    });

    test("missing runtime condition fields emit structured logs", () async {
      final List<SdkLogEntry> logs = <SdkLogEntry>[];
      final RevclustSdk sdk = RevclustSdk(
        config: SdkConfig(
          appVersion: "2.4.0",
          build: "24001",
          logger: logs.add,
        ),
        monotonicClockMs: () => 5000,
        runtimeConditionsProvider: _SingleSnapshotRuntimeConditionsProvider(
          const RuntimeConditionsSnapshot(
            deviceModel: "Pixel 9 Pro",
          ),
        ),
      );

      final PackBuildResult result = await sdk.buildPack(
        captureEnvelope: sdk.captureNow(reason: "missing runtime fields"),
      );

      final Map<String, Object?> conditions = _asObjectMap(
        result.payload["conditions"],
      );
      expect(conditions["device_model"], "Pixel 9 Pro");
      expect(conditions["os_version"], "unknown");
      expect(conditions["network_type"], "unknown");
      expect(logs, hasLength(1));
      expect(logs.single.code, SdkLogCodes.runtimeConditionsMissing);
      expect(
        logs.single.metadata["missing_fields"],
        <String>["os_version", "network_type"],
      );
    });

    test("delayed build uses state snapshot snapped at capture time", () async {
      final _MutableSnapshotSource source = _MutableSnapshotSource(
        screen: "checkout",
        cartCount: 2,
        orderId: "ord_12345",
      );
      final RevclustSdk sdk = RevclustSdk(
        config: SdkConfig(
          appVersion: "2.4.0",
          build: "24001",
          stateHashSalt: "app-salt",
        ),
        monotonicClockMs: () => 5000,
        stateSnapshotProvider: AllowlistedStateSnapshotProvider(
          appStateFields: <AppStateField>[
            AppStateField(
              key: "screen",
              readValue: () => source.screen,
            ),
          ],
          dataStateFields: <DataStateField>[
            DataStateField.value(
              key: "cart_count",
              readValue: () => source.cartCount,
            ),
            DataStateField.hashedDomainId(
              key: "order_id",
              readValue: () => source.orderId,
            ),
          ],
        ),
      );
      final CaptureEnvelope envelope =
          sdk.captureNow(reason: "checkout mismatch");

      source
        ..screen = "confirmation"
        ..cartCount = 9
        ..orderId = "ord_99999";

      final PackBuildResult result = await sdk.buildPack(
        captureEnvelope: envelope,
      );

      final Map<String, Object?> stateSnapshot = _asObjectMap(
        result.payload["state_snapshot"],
      );
      expect(
        _asObjectMap(stateSnapshot["app_state"]),
        <String, Object?>{"screen": "checkout"},
      );
      expect(
        _asObjectMap(stateSnapshot["data_state"])["cart_count"],
        2,
      );
      expect(
        _asObjectMap(stateSnapshot["data_state"])["order_id"],
        await _hashedDomainId("app-salt", "ord_12345"),
      );
    });

    test("checkpoint path preserves capture-time snapped runtime conditions",
        () async {
      final _SequencedRuntimeConditionsProvider provider =
          _SequencedRuntimeConditionsProvider(
        <RuntimeConditionsSnapshot>[
          const RuntimeConditionsSnapshot(
            deviceModel: "iPhone15,4",
            osVersion: "iOS 18.2",
            networkType: "cellular",
          ),
          const RuntimeConditionsSnapshot(
            deviceModel: "Pixel 9 Pro",
            osVersion: "Android 16",
            networkType: "wifi",
          ),
        ],
      );
      final _RecordingLocalPackRepository repository =
          _RecordingLocalPackRepository();
      final RevclustSdk sdk = RevclustSdk(
        config: SdkConfig(appVersion: "3.0.0", build: "30001"),
        monotonicClockMs: () => 6000,
        runtimeConditionsProvider: provider,
        localPackRepository: repository,
      );

      sdk.recordUiIntent(tMonoMs: 5500, name: "checkout.submit");
      sdk.recordLifecycleBackground(tMonoMs: 6000);
      await _waitForSavedResults(repository, expectedCount: 1);

      expect(provider.resolveCallCount, 1);
      expect(repository.savedResults, hasLength(1));
      final Map<String, Object?> conditions = _asObjectMap(
        repository.savedResults.single.payload["conditions"],
      );
      expect(conditions["device_model"], "iPhone15,4");
      expect(conditions["os_version"], "iOS 18.2");
      expect(conditions["network_type"], "cellular");
      expect(provider.resolveCallCount, 1);
    });

    test("checkpoint path preserves capture-time snapped state snapshot",
        () async {
      final _MutableSnapshotSource source = _MutableSnapshotSource(
        screen: "checkout",
        cartCount: 2,
        orderId: "ord_12345",
      );
      final _RecordingLocalPackRepository repository =
          _RecordingLocalPackRepository();
      final RevclustSdk sdk = RevclustSdk(
        config: SdkConfig(
          appVersion: "3.0.0",
          build: "30001",
          stateHashSalt: "app-salt",
        ),
        monotonicClockMs: () => 6000,
        stateSnapshotProvider: AllowlistedStateSnapshotProvider(
          appStateFields: <AppStateField>[
            AppStateField(
              key: "screen",
              readValue: () => source.screen,
            ),
          ],
          dataStateFields: <DataStateField>[
            DataStateField.value(
              key: "cart_count",
              readValue: () => source.cartCount,
            ),
            DataStateField.hashedDomainId(
              key: "order_id",
              readValue: () => source.orderId,
            ),
          ],
        ),
        localPackRepository: repository,
      );

      sdk.recordUiIntent(tMonoMs: 5500, name: "checkout.submit");
      sdk.recordLifecycleBackground(tMonoMs: 6000);

      source
        ..screen = "confirmation"
        ..cartCount = 9
        ..orderId = "ord_99999";

      await _waitForSavedResults(repository, expectedCount: 1);

      final Map<String, Object?> stateSnapshot = _asObjectMap(
        repository.savedResults.single.payload["state_snapshot"],
      );
      expect(
        _asObjectMap(stateSnapshot["app_state"]),
        <String, Object?>{"screen": "checkout"},
      );
      final Map<String, Object?> dataState = _asObjectMap(
        stateSnapshot["data_state"],
      );
      expect(dataState["cart_count"], 2);
      expect(
        dataState["order_id"],
        await _hashedDomainId("app-salt", "ord_12345"),
      );
    });
  });
}

class _ExceptionRuntimeConditionsProvider implements RuntimeConditionsProvider {
  @override
  Future<RuntimeConditionsSnapshot> resolve() async {
    throw Exception("runtime conditions unavailable");
  }
}

class _ErrorRuntimeConditionsProvider implements RuntimeConditionsProvider {
  @override
  Future<RuntimeConditionsSnapshot> resolve() async {
    throw StateError("runtime conditions provider bug");
  }
}

class _ExceptionStateSnapshotProvider extends AllowlistedStateSnapshotProvider {
  @override
  Future<StateSnapshot> capture({
    required int maxStateKeys,
    required int maxStateBytes,
    required int maxStringLen,
    String? hashSalt,
  }) async {
    throw Exception("state snapshot unavailable");
  }
}

class _SequencedRuntimeConditionsProvider implements RuntimeConditionsProvider {
  _SequencedRuntimeConditionsProvider(List<RuntimeConditionsSnapshot> snapshots)
      : _snapshots = List<RuntimeConditionsSnapshot>.from(snapshots);

  final List<RuntimeConditionsSnapshot> _snapshots;
  int resolveCallCount = 0;

  @override
  Future<RuntimeConditionsSnapshot> resolve() async {
    resolveCallCount += 1;
    if (_snapshots.isEmpty) {
      throw StateError("No runtime snapshots remaining.");
    }
    return _snapshots.removeAt(0);
  }
}

class _SingleSnapshotRuntimeConditionsProvider
    implements RuntimeConditionsProvider {
  _SingleSnapshotRuntimeConditionsProvider(this._snapshot);

  final RuntimeConditionsSnapshot _snapshot;

  @override
  Future<RuntimeConditionsSnapshot> resolve() async {
    return _snapshot;
  }
}

class _RecordingLocalPackRepository extends LocalPackRepository {
  _RecordingLocalPackRepository()
      : super(
          encryptionService: AesGcmEncryptionService(
            keyStore: InMemoryKeyStore(),
          ),
          databasePath: "/tmp/revclust_sdk_pack_build_test.db",
          databaseFactory: databaseFactoryFfiNoIsolate,
        );

  final List<PackBuildResult> savedResults = <PackBuildResult>[];

  @override
  Future<void> savePending(PackBuildResult result) async {
    savedResults.add(result);
  }
}

class _MutableSnapshotSource {
  _MutableSnapshotSource({
    required this.screen,
    required this.cartCount,
    required this.orderId,
  });

  String screen;
  int cartCount;
  String orderId;
}

Future<void> _waitForSavedResults(
  _RecordingLocalPackRepository repository, {
  required int expectedCount,
}) async {
  for (int attempt = 0; attempt < 20; attempt += 1) {
    if (repository.savedResults.length >= expectedCount) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError("Timed out waiting for checkpoint persistence.");
}

Map<String, Object?> _asObjectMap(Object? value) {
  return Map<String, Object?>.from(value as Map<Object?, Object?>);
}

Future<String> _hashedDomainId(String salt, String rawId) async {
  final Hash hash = await Sha256().hash(utf8.encode("$salt:$rawId"));
  final StringBuffer buffer = StringBuffer("sha256:");
  for (final int byte in hash.bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, "0"));
  }
  return buffer.toString();
}
