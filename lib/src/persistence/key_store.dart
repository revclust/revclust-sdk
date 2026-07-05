import "dart:convert";
import "dart:io";

import "package:flutter/services.dart";
import "package:flutter_secure_storage/flutter_secure_storage.dart";

const String revclustEncryptionKeyStorageKey = "revclust_encryption_key";

/// Adapter abstraction for reading/writing raw encryption key material.
abstract class KeyStore {
  Future<Uint8List?> readKeyMaterial();

  Future<void> writeKeyMaterial(Uint8List keyMaterial);
}

/// KeyStore backed by flutter_secure_storage.
class FlutterSecureStorageKeyStore implements KeyStore {
  FlutterSecureStorageKeyStore({
    FlutterSecureStorage? secureStorage,
    String storageKey = revclustEncryptionKeyStorageKey,
  })  : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
        _storageKey = _normalizeStorageKey(storageKey);

  final FlutterSecureStorage _secureStorage;
  final String _storageKey;

  @override
  Future<Uint8List?> readKeyMaterial() async {
    final String? encoded = await _secureStorage.read(key: _storageKey);
    if (encoded == null) {
      return null;
    }
    try {
      return Uint8List.fromList(base64Decode(encoded));
    } on FormatException catch (error) {
      throw StateError("Stored encryption key is invalid base64: $error");
    }
  }

  @override
  Future<void> writeKeyMaterial(Uint8List keyMaterial) async {
    if (keyMaterial.isEmpty) {
      throw ArgumentError.value(
        keyMaterial,
        "keyMaterial",
        "must not be empty",
      );
    }
    await _secureStorage.write(
      key: _storageKey,
      value: base64Encode(keyMaterial),
    );
  }

  static String _normalizeStorageKey(String storageKey) {
    final String normalized = storageKey.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        storageKey,
        "storageKey",
        "must not be empty",
      );
    }
    return normalized;
  }
}

/// KeyStore backed by an app-local file for desktop fallback.
class FileBackedKeyStore implements KeyStore {
  FileBackedKeyStore({
    required String filePath,
    File? file,
  }) : _file = file ?? File(_normalizeFilePath(filePath));

  final File _file;

  @override
  Future<Uint8List?> readKeyMaterial() async {
    if (!await _file.exists()) {
      return null;
    }
    final String encoded = (await _file.readAsString()).trim();
    if (encoded.isEmpty) {
      throw StateError("Stored file-backed encryption key is empty.");
    }
    try {
      return Uint8List.fromList(base64Decode(encoded));
    } on FormatException catch (error) {
      throw StateError(
        "Stored file-backed encryption key is invalid base64: $error",
      );
    }
  }

  @override
  Future<void> writeKeyMaterial(Uint8List keyMaterial) async {
    if (keyMaterial.isEmpty) {
      throw ArgumentError.value(
        keyMaterial,
        "keyMaterial",
        "must not be empty",
      );
    }
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      base64Encode(keyMaterial),
      flush: true,
    );
  }

  static String _normalizeFilePath(String filePath) {
    final String normalized = filePath.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        filePath,
        "filePath",
        "must not be empty",
      );
    }
    return normalized;
  }
}

/// Fallback wrapper for desktop runtimes without usable keyring access.
class DesktopFallbackKeyStore implements KeyStore {
  DesktopFallbackKeyStore({
    required KeyStore secureStorageKeyStore,
    required KeyStore fallbackKeyStore,
  })  : _secureStorageKeyStore = secureStorageKeyStore,
        _fallbackKeyStore = fallbackKeyStore;

  final KeyStore _secureStorageKeyStore;
  final KeyStore _fallbackKeyStore;

  @override
  Future<Uint8List?> readKeyMaterial() async {
    try {
      final Uint8List? secureStorageMaterial =
          await _secureStorageKeyStore.readKeyMaterial();
      if (secureStorageMaterial != null) {
        await _mirrorFallbackMaterial(secureStorageMaterial);
        return secureStorageMaterial;
      }
    } catch (error) {
      if (!isRevclustSecureStorageUnavailableError(error)) {
        rethrow;
      }
      return _fallbackKeyStore.readKeyMaterial();
    }
    return _fallbackKeyStore.readKeyMaterial();
  }

  @override
  Future<void> writeKeyMaterial(Uint8List keyMaterial) async {
    try {
      await _secureStorageKeyStore.writeKeyMaterial(keyMaterial);
      await _mirrorFallbackMaterial(keyMaterial);
      return;
    } catch (error) {
      if (!isRevclustSecureStorageUnavailableError(error)) {
        rethrow;
      }
    }
    await _fallbackKeyStore.writeKeyMaterial(keyMaterial);
  }

  Future<void> _mirrorFallbackMaterial(Uint8List keyMaterial) async {
    final Uint8List? fallbackMaterial =
        await _fallbackKeyStore.readKeyMaterial();
    if (_matchesKeyMaterial(fallbackMaterial, keyMaterial)) {
      return;
    }
    await _fallbackKeyStore.writeKeyMaterial(keyMaterial);
  }

  static bool _matchesKeyMaterial(
    Uint8List? existing,
    Uint8List expected,
  ) {
    if (existing == null || existing.lengthInBytes != expected.lengthInBytes) {
      return false;
    }
    for (int index = 0; index < expected.lengthInBytes; index++) {
      if (existing[index] != expected[index]) {
        return false;
      }
    }
    return true;
  }
}

bool isRevclustSecureStorageUnavailableError(Object error) {
  if (error is MissingPluginException) {
    return true;
  }
  if (error is PlatformException) {
    return _containsSecureStorageUnavailableSignal(error.code) ||
        _containsSecureStorageUnavailableSignal(error.message) ||
        _containsSecureStorageUnavailableSignal(error.details?.toString());
  }
  return _containsSecureStorageUnavailableSignal(error.toString());
}

bool _containsSecureStorageUnavailableSignal(String? value) {
  if (value == null) {
    return false;
  }
  final String lowerCased = value.toLowerCase();
  return lowerCased.contains("libsecret") ||
      lowerCased.contains("keyring") ||
      lowerCased.contains("keychain") ||
      lowerCased.contains("secret service") ||
      lowerCased.contains("failed to unlock");
}
