import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter_sdk/revclust_flutter_sdk.dart";

import "support/in_memory_key_store.dart";

void main() {
  group("DesktopPilotFallbackKeyStore", () {
    test("keeps using secure storage when it is available", () async {
      final InMemoryKeyStore secureStorageKeyStore = InMemoryKeyStore();
      final InMemoryKeyStore fallbackKeyStore = InMemoryKeyStore();
      final DesktopPilotFallbackKeyStore keyStore =
          DesktopPilotFallbackKeyStore(
        secureStorageKeyStore: secureStorageKeyStore,
        fallbackKeyStore: fallbackKeyStore,
      );
      final Uint8List material = Uint8List.fromList(<int>[1, 2, 3, 4]);

      await keyStore.writeKeyMaterial(material);

      expect(
        await keyStore.readKeyMaterial(),
        orderedEquals(material),
      );
      expect(
        await secureStorageKeyStore.readKeyMaterial(),
        orderedEquals(material),
      );
      expect(
        await fallbackKeyStore.readKeyMaterial(),
        orderedEquals(material),
      );
    });

    test("falls back when secure storage is unavailable", () async {
      final InMemoryKeyStore fallbackKeyStore = InMemoryKeyStore();
      final DesktopPilotFallbackKeyStore keyStore =
          DesktopPilotFallbackKeyStore(
        secureStorageKeyStore: _ThrowingUnavailableKeyStore(),
        fallbackKeyStore: fallbackKeyStore,
      );
      final Uint8List material = Uint8List.fromList(<int>[5, 6, 7, 8]);

      await keyStore.writeKeyMaterial(material);

      expect(
        await keyStore.readKeyMaterial(),
        orderedEquals(material),
      );
      expect(
        await fallbackKeyStore.readKeyMaterial(),
        orderedEquals(material),
      );
    });

    test("seeds fallback mirror when secure storage already has the key",
        () async {
      final InMemoryKeyStore secureStorageKeyStore = InMemoryKeyStore();
      final InMemoryKeyStore fallbackKeyStore = InMemoryKeyStore();
      final Uint8List material = Uint8List.fromList(<int>[13, 14, 15, 16]);
      await secureStorageKeyStore.writeKeyMaterial(material);

      final DesktopPilotFallbackKeyStore keyStore =
          DesktopPilotFallbackKeyStore(
        secureStorageKeyStore: secureStorageKeyStore,
        fallbackKeyStore: fallbackKeyStore,
      );

      expect(
        await keyStore.readKeyMaterial(),
        orderedEquals(material),
      );
      expect(
        await fallbackKeyStore.readKeyMaterial(),
        orderedEquals(material),
      );
    });

    test(
        "later keyring loss still returns the mirrored key from fallback storage",
        () async {
      final InMemoryKeyStore secureStorageKeyStore = InMemoryKeyStore();
      final InMemoryKeyStore fallbackKeyStore = InMemoryKeyStore();
      final Uint8List material = Uint8List.fromList(<int>[17, 18, 19, 20]);
      final DesktopPilotFallbackKeyStore firstSessionKeyStore =
          DesktopPilotFallbackKeyStore(
        secureStorageKeyStore: secureStorageKeyStore,
        fallbackKeyStore: fallbackKeyStore,
      );

      await firstSessionKeyStore.writeKeyMaterial(material);

      final DesktopPilotFallbackKeyStore secondSessionKeyStore =
          DesktopPilotFallbackKeyStore(
        secureStorageKeyStore: _ThrowingUnavailableKeyStore(),
        fallbackKeyStore: fallbackKeyStore,
      );

      expect(
        await secondSessionKeyStore.readKeyMaterial(),
        orderedEquals(material),
      );
    });

    test("uses fallback material when secure storage is empty", () async {
      final InMemoryKeyStore secureStorageKeyStore = InMemoryKeyStore();
      final InMemoryKeyStore fallbackKeyStore = InMemoryKeyStore();
      final DesktopPilotFallbackKeyStore keyStore =
          DesktopPilotFallbackKeyStore(
        secureStorageKeyStore: secureStorageKeyStore,
        fallbackKeyStore: fallbackKeyStore,
      );
      final Uint8List material = Uint8List.fromList(<int>[9, 10, 11, 12]);
      await fallbackKeyStore.writeKeyMaterial(material);

      expect(
        await keyStore.readKeyMaterial(),
        orderedEquals(material),
      );
    });
  });

  group("isRevclustSecureStorageUnavailableError", () {
    test("recognizes libsecret keyring failures", () {
      expect(
        isRevclustSecureStorageUnavailableError(
          PlatformException(
            code: "libsecret_error",
            message: "Failed to unlock the keyring",
          ),
        ),
        isTrue,
      );
    });

    test("does not hide unrelated secure storage corruption", () {
      expect(
        isRevclustSecureStorageUnavailableError(
          StateError("Stored encryption key is invalid base64."),
        ),
        isFalse,
      );
    });
  });
}

final class _ThrowingUnavailableKeyStore implements KeyStore {
  @override
  Future<Uint8List?> readKeyMaterial() async {
    throw PlatformException(
      code: "libsecret_error",
      message: "Failed to unlock the keyring",
    );
  }

  @override
  Future<void> writeKeyMaterial(Uint8List keyMaterial) async {
    throw PlatformException(
      code: "libsecret_error",
      message: "Failed to unlock the keyring",
    );
  }
}
