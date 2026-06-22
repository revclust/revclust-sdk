import "dart:convert";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter_sdk/src/internal/revclust_internal.dart";

import "support/in_memory_key_store.dart";

void main() {
  test("AES-GCM roundtrip encrypts and decrypts bytes", () async {
    final InMemoryKeyStore keyStore = InMemoryKeyStore();
    final AesGcmEncryptionService service = AesGcmEncryptionService(
      keyStore: keyStore,
    );
    final Uint8List plainBytes = Uint8List.fromList(
      utf8.encode("gzip payload bytes sample"),
    );

    final Uint8List cipherBlob = await service.encrypt(plainBytes);
    final Uint8List decrypted = await service.decrypt(cipherBlob);

    expect(decrypted, plainBytes);
  });

  test("blob format is nonce prefix + cipherText+tag", () async {
    final AesGcmEncryptionService service = AesGcmEncryptionService(
      keyStore: InMemoryKeyStore(),
    );
    final Uint8List plainBytes = Uint8List.fromList(
      utf8.encode("blob format check"),
    );

    final Uint8List cipherBlob = await service.encrypt(plainBytes);
    final ParsedEncryptedBlob parsed = service.parseCipherBlob(cipherBlob);

    expect(
        parsed.nonce.lengthInBytes, AesGcmEncryptionService.nonceBytesLength);
    expect(parsed.tag.lengthInBytes, AesGcmEncryptionService.tagBytesLength);

    final Uint8List expectedNonce = Uint8List.fromList(
      cipherBlob.sublist(0, AesGcmEncryptionService.nonceBytesLength),
    );
    final int cipherEnd =
        cipherBlob.lengthInBytes - AesGcmEncryptionService.tagBytesLength;
    final Uint8List expectedCipherText = Uint8List.fromList(
      cipherBlob.sublist(AesGcmEncryptionService.nonceBytesLength, cipherEnd),
    );
    final Uint8List expectedTag = Uint8List.fromList(
      cipherBlob.sublist(cipherEnd),
    );

    expect(parsed.nonce, expectedNonce);
    expect(parsed.cipherText, expectedCipherText);
    expect(parsed.tag, expectedTag);
  });

  test("blob parser rejects malformed lengths deterministically", () {
    final AesGcmEncryptionService service = AesGcmEncryptionService(
      keyStore: InMemoryKeyStore(),
    );

    expect(
      () => service.parseCipherBlob(
        Uint8List(AesGcmEncryptionService.minCipherBlobBytes - 1),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => service.parseCipherBlob(Uint8List(0)),
      throwsA(isA<FormatException>()),
    );
  });
}
