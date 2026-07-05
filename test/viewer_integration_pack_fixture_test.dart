import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "support/viewer_integration_pack_fixture.dart";

void main() {
  test("viewer integration fixture stays SDK-generated and incident-relevant",
      () async {
    final result = await buildViewerIntegrationFixturePack();
    final Map<String, Object?> fixturePayload = _readFixturePayload();

    expect(result.payload, equals(fixturePayload));

    final Map<String, Object?> conditions = _asObjectMap(
      result.payload["conditions"],
    );
    expect(conditions["device_model"], "Pixel 9 Pro");
    expect(conditions["os_version"], "Android 16");
    expect(conditions["network_type"], "wifi");
    expect(conditions["app_release_stage"], "staging");

    final Map<String, Object?> stateSnapshot = _asObjectMap(
      result.payload["state_snapshot"],
    );
    expect(_asObjectMap(stateSnapshot["app_state"])["screen"], "checkout");
    expect(_asObjectMap(stateSnapshot["data_state"])["cart_count"], 2);

    final Map<String, Object?> truncation = _asObjectMap(
      result.payload["truncation"],
    );
    expect(truncation["truncated"], isTrue);
  });
}

Map<String, Object?> _readFixturePayload() {
  final File fixtureFile = File("test/fixtures/viewer_integration_pack.json");
  return _asObjectMap(jsonDecode(fixtureFile.readAsStringSync()));
}

Map<String, Object?> _asObjectMap(Object? value) {
  return Map<String, Object?>.from(value as Map<Object?, Object?>);
}
