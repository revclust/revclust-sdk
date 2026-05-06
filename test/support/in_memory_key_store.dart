import "dart:typed_data";

import "package:revclust_flutter_sdk/revclust_flutter_sdk.dart";

class InMemoryKeyStore implements KeyStore {
  Uint8List? _material;

  @override
  Future<Uint8List?> readKeyMaterial() async {
    final Uint8List? current = _material;
    if (current == null) {
      return null;
    }
    return Uint8List.fromList(current);
  }

  @override
  Future<void> writeKeyMaterial(Uint8List keyMaterial) async {
    _material = Uint8List.fromList(keyMaterial);
  }
}
