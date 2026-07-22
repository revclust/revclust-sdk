import "dart:async";
import "dart:convert";

import "package:cryptography/cryptography.dart";
import "package:cryptography/dart.dart";
import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter/src/internal/revclust_internal.dart";

void main() {
  group("state snapshot", () {
    test("outer snapshot future normalizes Exception to empty snapshot",
        () async {
      final CapturedStateSnapshot snapshotHandle = CapturedStateSnapshot.future(
        Future<StateSnapshot>.error(Exception("state snapshot unavailable")),
      );

      final StateSnapshot snapshot = await snapshotHandle.resolve();
      expect(snapshot.appState, isEmpty);
      expect(snapshot.dataState, isEmpty);
    });

    test("outer snapshot future does not normalize non-Exception failures",
        () async {
      final CapturedStateSnapshot snapshotHandle = CapturedStateSnapshot.future(
        Future<StateSnapshot>.error(StateError("state snapshot bug")),
      );

      expect(
        snapshotHandle.resolve(),
        throwsA(isA<StateError>()),
      );
    });

    test(
      "allowlisted app/data state appears in built pack and excludes other fields",
      () async {
        final _MutableState state = _MutableState();
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
                key: "logged_in",
                readValue: () => state.loggedIn,
              ),
              AppStateField(
                key: "step",
                readValue: () => state.step,
              ),
              AppStateField(
                key: "note",
                readValue: () => state.note,
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
        );

        final PackBuildResult result = await sdk.buildPack(
          captureEnvelope: sdk.captureNow(reason: "checkout mismatch"),
        );

        final Map<String, Object?> stateSnapshot = _asObjectMap(
          result.payload["state_snapshot"],
        );
        expect(
          _asObjectMap(stateSnapshot["app_state"]),
          <String, Object?>{
            "logged_in": true,
            "note": "ready",
            "step": "shipping",
          },
        );
        expect(
          _asObjectMap(stateSnapshot["data_state"]),
          <String, Object?>{
            "cart_count": 2,
            "order_id": await _expectedHash("app-salt", "ord_12345"),
          },
        );

        final String payloadJson = jsonEncode(result.payload);
        expect(payloadJson.contains("sensitive-state-marker"), isFalse);
        expect(payloadJson.contains("ord_12345"), isFalse);
      },
    );

    test("truncates strings and omits unsupported values deterministically",
        () async {
      final List<SdkLogEntry> logs = <SdkLogEntry>[];
      final AllowlistedStateSnapshotProvider provider =
          AllowlistedStateSnapshotProvider(
        appStateFields: <AppStateField>[
          AppStateField(
            key: "long_text",
            readValue: () => "abcdefgh",
          ),
          AppStateField(
            key: "step",
            readValue: () => _CheckoutStep.shipping,
          ),
          AppStateField(
            key: "unsupported",
            readValue: () => <String>["x"],
          ),
        ],
        logger: logs.add,
      );

      final StateSnapshot snapshot = await provider.capture(
        maxStateKeys: 10,
        maxStateBytes: 1024,
        maxStringLen: 5,
      );

      expect(
        snapshot.appState,
        <String, Object?>{
          "long_text": "abcde",
          "step": "shipp",
        },
      );
      expect(logs, hasLength(1));
      expect(logs.single.code, SdkLogCodes.stateSnapshotOmitted);
      expect(
        _asObjectMap(logs.single.metadata["omitted_fields_by_reason"]),
        <String, Object?>{
          "unsupported_or_missing": <String>["app_state.unsupported"],
        },
      );
    });

    test("enforces maxStateKeys deterministically", () async {
      final AllowlistedStateSnapshotProvider provider =
          AllowlistedStateSnapshotProvider(
        appStateFields: <AppStateField>[
          AppStateField(key: "beta", readValue: () => 2),
          AppStateField(key: "alpha", readValue: () => 1),
          AppStateField(key: "gamma", readValue: () => 3),
        ],
        dataStateFields: <DataStateField>[
          DataStateField.value(key: "delta", readValue: () => 4),
        ],
      );

      final StateSnapshot snapshot = await provider.capture(
        maxStateKeys: 2,
        maxStateBytes: 1024,
        maxStringLen: 32,
      );

      expect(snapshot.appState, <String, Object?>{"alpha": 1, "beta": 2});
      expect(snapshot.dataState, isEmpty);
    });

    test("enforces maxStateBytes deterministically", () async {
      final AllowlistedStateSnapshotProvider provider =
          AllowlistedStateSnapshotProvider(
        appStateFields: <AppStateField>[
          AppStateField(key: "alpha", readValue: () => "aa"),
          AppStateField(key: "beta", readValue: () => "bbbbbbbbbbbb"),
          AppStateField(key: "gamma", readValue: () => "cc"),
        ],
      );

      final int capBytes = _snapshotJsonBytes(
        appState: <String, Object?>{"alpha": "aa", "gamma": "cc"},
      );
      final StateSnapshot snapshot = await provider.capture(
        maxStateKeys: 10,
        maxStateBytes: capBytes,
        maxStringLen: 32,
      );

      expect(
        snapshot.appState,
        <String, Object?>{"alpha": "aa", "gamma": "cc"},
      );
      expect(snapshot.appState.containsKey("beta"), isFalse);
    });

    test("combined maxStateKeys and maxStateBytes remain deterministic",
        () async {
      final AllowlistedStateSnapshotProvider provider =
          AllowlistedStateSnapshotProvider(
        appStateFields: <AppStateField>[
          AppStateField(key: "alpha", readValue: () => "aa"),
          AppStateField(
            key: "beta",
            readValue: () => "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          ),
          AppStateField(key: "gamma", readValue: () => "cc"),
        ],
        dataStateFields: <DataStateField>[
          DataStateField.value(key: "delta", readValue: () => 4),
        ],
      );

      final int capBytes = _snapshotJsonBytes(
        appState: <String, Object?>{"alpha": "aa", "gamma": "cc"},
        dataState: <String, Object?>{"delta": 4},
      );
      final StateSnapshot snapshot = await provider.capture(
        maxStateKeys: 3,
        maxStateBytes: capBytes,
        maxStringLen: 32,
      );

      expect(
        snapshot.appState,
        <String, Object?>{"alpha": "aa", "gamma": "cc"},
      );
      expect(snapshot.dataState, <String, Object?>{"delta": 4});
      expect(snapshot.appState.containsKey("beta"), isFalse);
    });

    test("hashed domain ids are stable and do not expose raw ids", () async {
      final AllowlistedStateSnapshotProvider provider =
          AllowlistedStateSnapshotProvider(
        dataStateFields: <DataStateField>[
          DataStateField.hashedDomainId(
            key: "account_id",
            readValue: () => 42,
          ),
        ],
      );

      final StateSnapshot first = await provider.capture(
        maxStateKeys: 10,
        maxStateBytes: 1024,
        maxStringLen: 32,
        hashSalt: "app-salt",
      );
      final StateSnapshot second = await provider.capture(
        maxStateKeys: 10,
        maxStateBytes: 1024,
        maxStringLen: 32,
        hashSalt: "app-salt",
      );

      final String expected = await _expectedHash("app-salt", "42");
      expect(first.dataState["account_id"], expected);
      expect(second.dataState["account_id"], expected);
      expect(jsonEncode(first.dataState).contains("\"42\""), isFalse);
    });

    test("omission logs do not expose raw domain ids", () async {
      final List<SdkLogEntry> logs = <SdkLogEntry>[];
      final AllowlistedStateSnapshotProvider provider =
          AllowlistedStateSnapshotProvider(
        dataStateFields: <DataStateField>[
          DataStateField.hashedDomainId(
            key: "order_id",
            readValue: () => "ord_12345",
          ),
        ],
        hashAlgorithm: _FailingHashAlgorithm(),
        logger: logs.add,
      );

      final StateSnapshot snapshot = await provider.capture(
        maxStateKeys: 10,
        maxStateBytes: 1024,
        maxStringLen: 32,
        hashSalt: "app-salt",
      );

      expect(snapshot.dataState, isEmpty);
      expect(logs, hasLength(1));
      expect(logs.single.code, SdkLogCodes.stateSnapshotOmitted);
      expect(
        _asObjectMap(logs.single.metadata["omitted_fields_by_reason"]),
        <String, Object?>{
          "hash_or_invalid_domain_id": <String>["data_state.order_id"],
        },
      );
      expect(jsonEncode(logs.single.metadata).contains("ord_12345"), isFalse);
    });

    test(
      "hashed domain ids use values snapped before async hashing completes",
      () async {
        final Completer<void> hashGate = Completer<void>();
        final _MutableState state = _MutableState();
        final AllowlistedStateSnapshotProvider provider =
            AllowlistedStateSnapshotProvider(
          dataStateFields: <DataStateField>[
            DataStateField.hashedDomainId(
              key: "order_id",
              readValue: () => state.orderId,
            ),
          ],
          hashAlgorithm: _DelayedHashAlgorithm(gate: hashGate.future),
        );

        final Future<StateSnapshot> snapshotFuture = provider.capture(
          maxStateKeys: 10,
          maxStateBytes: 1024,
          maxStringLen: 32,
          hashSalt: "app-salt",
        );

        state.orderId = "ord_99999";
        hashGate.complete();

        final StateSnapshot snapshot = await snapshotFuture;
        expect(
          snapshot.dataState["order_id"],
          await _expectedHash("app-salt", "ord_12345"),
        );
      },
    );

    test("sdk rejects hashed domain ids without configured salt", () {
      expect(
        () => RevclustSdk(
          config: SdkConfig(),
          stateSnapshotProvider: AllowlistedStateSnapshotProvider(
            dataStateFields: <DataStateField>[
              DataStateField.hashedDomainId(
                key: "order_id",
                readValue: () => "ord_12345",
              ),
            ],
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}

class _MutableState {
  bool loggedIn = true;
  _CheckoutStep step = _CheckoutStep.shipping;
  String note = "ready";
  int cartCount = 2;
  String orderId = "ord_12345";
  String privateMarker = "sensitive-state-marker";
}

class _DelayedHashAlgorithm implements HashAlgorithm {
  _DelayedHashAlgorithm({
    required Future<void> gate,
    HashAlgorithm? delegate,
  })  : _gate = gate,
        _delegate = delegate ?? Sha256();

  final Future<void> _gate;
  final HashAlgorithm _delegate;

  @override
  int get blockLengthInBytes => _delegate.blockLengthInBytes;

  @override
  int get hashCode => Object.hash(_gate, _delegate);

  @override
  int get hashLengthInBytes => _delegate.hashLengthInBytes;

  @override
  Future<Hash> hash(List<int> input) async {
    await _gate;
    return _delegate.hash(input);
  }

  @override
  HashSink newHashSink() {
    return _delegate.newHashSink();
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other);
  }

  @override
  DartHashAlgorithm toSync() {
    return _delegate.toSync();
  }
}

class _FailingHashAlgorithm implements HashAlgorithm {
  @override
  int get blockLengthInBytes => 64;

  @override
  int get hashCode => 0;

  @override
  int get hashLengthInBytes => 32;

  @override
  bool operator ==(Object other) {
    return identical(this, other);
  }

  @override
  Future<Hash> hash(List<int> input) async {
    throw Exception("hash failure for ord_12345");
  }

  @override
  HashSink newHashSink() {
    throw UnimplementedError();
  }

  @override
  DartHashAlgorithm toSync() {
    throw UnimplementedError();
  }
}

enum _CheckoutStep {
  shipping,
}

Map<String, Object?> _asObjectMap(Object? value) {
  return Map<String, Object?>.from(value as Map<Object?, Object?>);
}

int _snapshotJsonBytes({
  Map<String, Object?> appState = const <String, Object?>{},
  Map<String, Object?> dataState = const <String, Object?>{},
}) {
  return utf8
      .encode(
        jsonEncode(<String, Object?>{
          "app_state": appState,
          "data_state": dataState,
        }),
      )
      .length;
}

Future<String> _expectedHash(String salt, String rawId) async {
  final Hash hash = await Sha256().hash(utf8.encode("$salt:$rawId"));
  final StringBuffer buffer = StringBuffer("sha256:");
  for (final int byte in hash.bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, "0"));
  }
  return buffer.toString();
}
