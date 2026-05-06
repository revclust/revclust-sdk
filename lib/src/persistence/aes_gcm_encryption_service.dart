import "dart:typed_data";

import "package:cryptography/cryptography.dart";

import "key_store.dart";

/// Parsed view of encrypted blob layout:
/// [12-byte nonce] || [ciphertext + 16-byte tag].
class ParsedEncryptedBlob {
  ParsedEncryptedBlob({
    required this.nonce,
    required this.cipherText,
    required this.tag,
  });

  final Uint8List nonce;
  final Uint8List cipherText;
  final Uint8List tag;
}

/// AES-GCM encrypt/decrypt service for pack gzip bytes.
class AesGcmEncryptionService {
  AesGcmEncryptionService({
    required KeyStore keyStore,
    AesGcm? algorithm,
  })  : _keyStore = keyStore,
        _algorithm = algorithm ?? AesGcm.with256bits();

  static const int keyBytesLength = 32;
  static const int nonceBytesLength = 12;
  static const int tagBytesLength = 16;
  static const int minCipherBlobBytes = nonceBytesLength + tagBytesLength;

  final KeyStore _keyStore;
  final AesGcm _algorithm;

  SecretKey? _cachedSecretKey;

  Future<Uint8List> encrypt(Uint8List plainBytes) async {
    final SecretKey key = await _loadOrCreateSecretKey();
    final List<int> nonce = _algorithm.newNonce();
    if (nonce.length != nonceBytesLength) {
      throw StateError(
        "Unexpected AES-GCM nonce length: ${nonce.length}, "
        "expected $nonceBytesLength.",
      );
    }

    final SecretBox secretBox = await _algorithm.encrypt(
      plainBytes,
      secretKey: key,
      nonce: nonce,
    );
    if (secretBox.mac.bytes.length != tagBytesLength) {
      throw StateError(
        "Unexpected AES-GCM tag length: ${secretBox.mac.bytes.length}, "
        "expected $tagBytesLength.",
      );
    }

    final Uint8List cipherBlob = Uint8List(
      nonceBytesLength + secretBox.cipherText.length + tagBytesLength,
    );
    cipherBlob.setRange(0, nonceBytesLength, nonce);
    cipherBlob.setRange(
      nonceBytesLength,
      nonceBytesLength + secretBox.cipherText.length,
      secretBox.cipherText,
    );
    cipherBlob.setRange(
      nonceBytesLength + secretBox.cipherText.length,
      cipherBlob.lengthInBytes,
      secretBox.mac.bytes,
    );
    return cipherBlob;
  }

  Future<Uint8List> decrypt(Uint8List cipherBlob) async {
    final ParsedEncryptedBlob parsed = parseCipherBlob(cipherBlob);
    final SecretBox secretBox = SecretBox(
      parsed.cipherText,
      nonce: parsed.nonce,
      mac: Mac(parsed.tag),
    );

    final SecretKey key = await _loadOrCreateSecretKey();
    final List<int> plainBytes = await _algorithm.decrypt(
      secretBox,
      secretKey: key,
    );
    return Uint8List.fromList(plainBytes);
  }

  ParsedEncryptedBlob parseCipherBlob(Uint8List cipherBlob) {
    if (cipherBlob.lengthInBytes < minCipherBlobBytes) {
      throw FormatException(
        "Cipher blob must be at least $minCipherBlobBytes bytes "
        "(12-byte nonce + 16-byte tag).",
      );
    }

    final Uint8List nonce = Uint8List.fromList(
      cipherBlob.sublist(0, nonceBytesLength),
    );
    final Uint8List cipherAndTag = Uint8List.fromList(
      cipherBlob.sublist(nonceBytesLength),
    );
    if (cipherAndTag.lengthInBytes < tagBytesLength) {
      throw FormatException(
        "Cipher segment must be at least $tagBytesLength bytes for tag.",
      );
    }

    final int cipherTextLength = cipherAndTag.lengthInBytes - tagBytesLength;
    final Uint8List cipherText = Uint8List.fromList(
      cipherAndTag.sublist(0, cipherTextLength),
    );
    final Uint8List tag = Uint8List.fromList(
      cipherAndTag.sublist(cipherTextLength),
    );

    return ParsedEncryptedBlob(
      nonce: nonce,
      cipherText: cipherText,
      tag: tag,
    );
  }

  Future<SecretKey> _loadOrCreateSecretKey() async {
    final SecretKey? cached = _cachedSecretKey;
    if (cached != null) {
      return cached;
    }

    final Uint8List? storedKeyMaterial = await _keyStore.readKeyMaterial();
    if (storedKeyMaterial == null) {
      final SecretKey generated = await _algorithm.newSecretKey();
      final Uint8List generatedBytes = Uint8List.fromList(
        await generated.extractBytes(),
      );
      _validateKeyLength(generatedBytes);
      await _keyStore.writeKeyMaterial(generatedBytes);
      final SecretKey loaded = SecretKey(generatedBytes);
      _cachedSecretKey = loaded;
      return loaded;
    }

    _validateKeyLength(storedKeyMaterial);
    final SecretKey loaded = SecretKey(storedKeyMaterial);
    _cachedSecretKey = loaded;
    return loaded;
  }

  static void _validateKeyLength(Uint8List keyMaterial) {
    if (keyMaterial.lengthInBytes != keyBytesLength) {
      throw StateError(
        "Invalid AES-256 key length ${keyMaterial.lengthInBytes}; "
        "expected $keyBytesLength.",
      );
    }
  }
}
