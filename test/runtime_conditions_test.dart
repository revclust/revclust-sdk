import "package:connectivity_plus/connectivity_plus.dart";
import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter/src/internal/revclust_internal.dart";

void main() {
  group("FlutterRuntimeConditionsProvider", () {
    test("maps connectivity results into schema network types", () async {
      final RuntimeConditionsSnapshot wifi =
          await _providerFor(<ConnectivityResult>[ConnectivityResult.wifi])
              .resolve();
      final RuntimeConditionsSnapshot ethernet =
          await _providerFor(<ConnectivityResult>[ConnectivityResult.ethernet])
              .resolve();
      final RuntimeConditionsSnapshot cellular =
          await _providerFor(<ConnectivityResult>[ConnectivityResult.mobile])
              .resolve();
      final RuntimeConditionsSnapshot offline =
          await _providerFor(<ConnectivityResult>[ConnectivityResult.none])
              .resolve();
      final RuntimeConditionsSnapshot unknown =
          await _providerFor(<ConnectivityResult>[ConnectivityResult.other])
              .resolve();

      expect(wifi.networkType, "wifi");
      expect(ethernet.networkType, "wifi");
      expect(cellular.networkType, "cellular");
      expect(offline.networkType, "offline");
      expect(unknown.networkType, isNull);
    });

    test("prefers wifi when mixed connectivity results are present", () async {
      final RuntimeConditionsSnapshot snapshot = await _providerFor(
        <ConnectivityResult>[
          ConnectivityResult.mobile,
          ConnectivityResult.wifi,
        ],
      ).resolve();

      expect(snapshot.networkType, "wifi");
    });

    test("falls back per field when readers throw", () async {
      final FlutterRuntimeConditionsProvider provider =
          FlutterRuntimeConditionsProvider(
        deviceConditionsReader: () async {
          throw Exception("device unavailable");
        },
        connectivityResultsReader: () async {
          throw Exception("network unavailable");
        },
      );

      final RuntimeConditionsSnapshot snapshot = await provider.resolve();

      expect(snapshot.deviceModel, isNull);
      expect(snapshot.osVersion, isNull);
      expect(snapshot.networkType, isNull);
    });

    test("preserves network when device reader fails", () async {
      final FlutterRuntimeConditionsProvider provider =
          FlutterRuntimeConditionsProvider(
        deviceConditionsReader: () async {
          throw Exception("device unavailable");
        },
        connectivityResultsReader: () async =>
            <ConnectivityResult>[ConnectivityResult.wifi],
      );

      final RuntimeConditionsSnapshot snapshot = await provider.resolve();

      expect(snapshot.deviceModel, isNull);
      expect(snapshot.osVersion, isNull);
      expect(snapshot.networkType, "wifi");
    });

    test("preserves device fields when connectivity reader fails", () async {
      final FlutterRuntimeConditionsProvider provider =
          FlutterRuntimeConditionsProvider(
        deviceConditionsReader: () async => const RuntimeConditionsSnapshot(
          deviceModel: "Pixel 9",
          osVersion: "Android 16",
        ),
        connectivityResultsReader: () async {
          throw Exception("network unavailable");
        },
      );

      final RuntimeConditionsSnapshot snapshot = await provider.resolve();

      expect(snapshot.deviceModel, "Pixel 9");
      expect(snapshot.osVersion, "Android 16");
      expect(snapshot.networkType, isNull);
    });
  });
}

FlutterRuntimeConditionsProvider _providerFor(
  List<ConnectivityResult> results,
) {
  return FlutterRuntimeConditionsProvider(
    deviceConditionsReader: () async => const RuntimeConditionsSnapshot(
      deviceModel: "Pixel 9",
      osVersion: "Android 16",
    ),
    connectivityResultsReader: () async => results,
  );
}
