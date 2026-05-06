import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "../test/support/viewer_integration_pack_fixture.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("writes the viewer integration pack fixture", () async {
    final result = await buildViewerIntegrationFixturePack();
    final JsonEncoder encoder = JsonEncoder.withIndent("  ");
    final File outputFile = File("test/fixtures/viewer_integration_pack.json");

    await outputFile.parent.create(recursive: true);
    await outputFile.writeAsString("${encoder.convert(result.payload)}\n");
  });
}
