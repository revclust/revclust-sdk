import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter/src/internal/revclust_internal.dart";

void main() {
  test("builds non-truncated payload with defaults and gzip bytes", () {
    final PackBuilder builder = PackBuilder();
    final CaptureEnvelope envelope = _envelope(
      timeline: <TimelineEvent>[
        TimelineEvent(
          eventType: "ui.intent",
          tMonoMs: 101,
          attributes: const <String, Object?>{"name": "submit"},
        ),
        TimelineEvent(
          eventType: "network",
          tMonoMs: 150,
          attributes: const <String, Object?>{
            "method": "POST",
            "sanitizedPath": "/api/v1/packs/{id}",
            "status": 201,
          },
        ),
      ],
    );

    final PackBuildResult result = builder.build(
      PackBuildRequest(
        captureEnvelope: envelope,
        sessionId: _sessionId,
        updateContextSnapshot: UpdateContextSnapshot.update(
          prevAppVersion: "1.2.9",
        ),
        appVersion: "1.3.0",
        build: "13045",
        deviceModel: "Pixel 8",
        osVersion: "Android 15",
        networkType: "wifi",
      ),
    );

    expect(result.truncated, isFalse);
    expect(result.gzipBytes.lengthInBytes, lessThanOrEqualTo(512 * 1024));

    final Map<String, Object?> payload = result.payload;
    expect(payload["schema_version"], "1.0.0");
    expect(payload["capture_id"], envelope.captureId);
    expect(payload["session_id"], _sessionId);

    final Map<String, Object?> trigger = _asObjectMap(payload["trigger"]);
    expect(trigger["trigger_utc_ms"], envelope.triggerUtcMs);
    expect(trigger["trigger_mono_ms"], envelope.triggerMonoMs);

    final Map<String, Object?> stateSnapshot = _asObjectMap(
      payload["state_snapshot"],
    );
    expect(_asObjectMap(stateSnapshot["app_state"]), isEmpty);
    expect(_asObjectMap(stateSnapshot["data_state"]), isEmpty);

    final String decodedJson = utf8.decode(GZipCodec().decode(
      result.gzipBytes,
    ));
    final Map<String, Object?> decodedPayload = _asObjectMap(
      jsonDecode(decodedJson),
    );
    expect(decodedPayload, equals(payload));
  });

  test("truncates oldest-first and updates truncation counters", () {
    final List<SdkLogEntry> logs = <SdkLogEntry>[];
    final PackBuilder builder = PackBuilder(logger: logs.add);
    final TimelineEvent first = TimelineEvent(
      eventType: "lifecycle.foreground",
      tMonoMs: 1000,
      attributes: <String, Object?>{
        "blob": _blob(seed: 1, length: 2400),
      },
    );
    final TimelineEvent second = TimelineEvent(
      eventType: "network",
      tMonoMs: 1001,
      attributes: <String, Object?>{
        "method": "GET",
        "sanitizedPath": "/users/{id}",
        "blob": _blob(seed: 2, length: 1200),
      },
    );
    final TimelineEvent third = TimelineEvent(
      eventType: "ui.intent",
      tMonoMs: 1002,
      attributes: <String, Object?>{
        "name": "tap.checkout",
        "blob": _blob(seed: 3, length: 1200),
      },
    );

    final CaptureEnvelope allEventsEnvelope = _envelope(
      timeline: <TimelineEvent>[first, second, third],
    );
    final CaptureEnvelope afterFirstDropEnvelope = _envelope(
      timeline: <TimelineEvent>[second, third],
    );

    final PackBuildRequest wideCapRequest = _request(
      envelope: allEventsEnvelope,
      maxPackBytesGzip: 2 * 1024 * 1024,
    );
    final PackBuildRequest wideCapAfterDropRequest = _request(
      envelope: afterFirstDropEnvelope,
      maxPackBytesGzip: 2 * 1024 * 1024,
    );

    final PackBuildResult allEvents = builder.build(wideCapRequest);
    final PackBuildResult afterFirstDrop =
        builder.build(wideCapAfterDropRequest);
    expect(
      allEvents.gzipBytes.lengthInBytes,
      greaterThan(afterFirstDrop.gzipBytes.lengthInBytes),
    );

    final int tightCap = afterFirstDrop.gzipBytes.lengthInBytes;
    final PackBuildResult result = builder.build(
      _request(envelope: allEventsEnvelope, maxPackBytesGzip: tightCap),
    );

    final Map<String, Object?> payload = result.payload;
    final List<Object?> timeline = _asObjectList(payload["timeline"]);
    final List<TimelineEvent> originalOrder = <TimelineEvent>[
      first,
      second,
      third
    ];
    final int droppedEventCount = originalOrder.length - timeline.length;

    expect(result.truncated, isTrue);
    expect(droppedEventCount, greaterThan(0));
    expect(timeline.length, inInclusiveRange(0, 2));
    expect(result.gzipBytes.lengthInBytes, lessThanOrEqualTo(tightCap));

    for (int index = 0; index < timeline.length; index += 1) {
      final String eventType =
          _asObjectMap(timeline[index])["event_type"] as String;
      final String expectedType =
          originalOrder[droppedEventCount + index].eventType;
      expect(eventType, expectedType);
    }

    final Map<String, Object?> truncation = _asObjectMap(payload["truncation"]);
    expect(truncation["truncated"], isTrue);

    final Map<String, Object?> droppedCounts = _asObjectMap(
      truncation["dropped_counts_by_type"],
    );

    final List<TimelineEvent> droppedEvents =
        originalOrder.take(droppedEventCount).toList(growable: false);
    final Map<String, int> expectedDroppedCounts = <String, int>{};
    for (final TimelineEvent event in droppedEvents) {
      expectedDroppedCounts.update(
        event.eventType,
        (int count) => count + 1,
        ifAbsent: () => 1,
      );
    }

    final int expectedDroppedBytes = droppedEvents
        .map(_timelineEventEncodedBytes)
        .fold(0, (int total, int value) => total + value);
    expect(droppedCounts, expectedDroppedCounts);
    expect(truncation["dropped_bytes"], expectedDroppedBytes);
    expect(result.droppedBytes, expectedDroppedBytes);
    expect(result.droppedCountsByType, expectedDroppedCounts);
    expect(logs, hasLength(1));
    expect(logs.single.code, SdkLogCodes.packTruncated);
    expect(logs.single.level, SdkLogLevel.warning);
    expect(logs.single.metadata["capture_id"], allEventsEnvelope.captureId);
    expect(logs.single.metadata["dropped_bytes"], expectedDroppedBytes);
    expect(logs.single.metadata["dropped_event_count"], droppedEventCount);
    expect(
      _asObjectMap(logs.single.metadata["dropped_counts_by_type"]),
      expectedDroppedCounts,
    );
  });

  test("truncation never drops trigger, conditions, or state snapshot", () {
    final PackBuilder builder = PackBuilder();
    final TimelineEvent first = TimelineEvent(
      eventType: "lifecycle.foreground",
      tMonoMs: 1000,
      attributes: <String, Object?>{"blob": _blob(seed: 1, length: 2400)},
    );
    final TimelineEvent second = TimelineEvent(
      eventType: "network",
      tMonoMs: 1001,
      attributes: <String, Object?>{
        "method": "GET",
        "sanitizedPath": "/users/{id}",
        "blob": _blob(seed: 2, length: 1200),
      },
    );
    final TimelineEvent third = TimelineEvent(
      eventType: "ui.intent",
      tMonoMs: 1002,
      attributes: <String, Object?>{
        "name": "tap.checkout",
        "blob": _blob(seed: 3, length: 1200),
      },
    );

    final CaptureEnvelope fullEnvelope = _envelope(
      timeline: <TimelineEvent>[first, second, third],
    );
    final CaptureEnvelope afterFirstDropEnvelope = _envelope(
      timeline: <TimelineEvent>[second, third],
    );
    final PackBuildResult baseline = builder.build(
      _request(envelope: fullEnvelope, maxPackBytesGzip: 2 * 1024 * 1024),
    );
    final PackBuildResult afterFirstDrop = builder.build(
      _request(
        envelope: afterFirstDropEnvelope,
        maxPackBytesGzip: 2 * 1024 * 1024,
      ),
    );

    final PackBuildResult result = builder.build(
      _request(
        envelope: fullEnvelope,
        maxPackBytesGzip: afterFirstDrop.gzipBytes.lengthInBytes,
      ),
    );

    final Map<String, Object?> payload = result.payload;

    expect(result.truncated, isTrue);
    expect(payload["trigger"], baseline.payload["trigger"]);
    expect(payload["conditions"], baseline.payload["conditions"]);
    expect(payload["state_snapshot"], baseline.payload["state_snapshot"]);
  });

  test("uses required placeholders and excludes them from missing_fields", () {
    final PackBuilder builder = PackBuilder();

    final PackBuildResult result = builder.build(
      PackBuildRequest(
        captureEnvelope: _envelope(),
        sessionId: _sessionId,
      ),
    );

    final Map<String, Object?> conditions = _asObjectMap(
      result.payload["conditions"],
    );
    expect(conditions["app_version"], "unknown");
    expect(conditions["build"], "unknown");
    expect(conditions["device_model"], "unknown");
    expect(conditions["os_version"], "unknown");
    expect(conditions["network_type"], "unknown");

    final List<Object?> missingFields = _asObjectList(
      result.payload["missing_fields"],
    );
    expect(missingFields.contains("conditions.app_version"), isFalse);
    expect(missingFields.contains("conditions.build"), isFalse);
    expect(missingFields.contains("conditions.device_model"), isFalse);
    expect(missingFields.contains("conditions.os_version"), isFalse);
    expect(missingFields.contains("conditions.network_type"), isFalse);
  });

  test("omits optional fields and lists them in deterministic missing_fields",
      () {
    final PackBuilder builder = PackBuilder();

    final PackBuildResult result = builder.build(
      PackBuildRequest(
        captureEnvelope: _envelope(),
        sessionId: _sessionId,
        appVersion: "1.0.0",
        build: "1000",
        deviceModel: "Pixel",
        osVersion: "Android 15",
        networkType: "wifi",
      ),
    );

    final Map<String, Object?> conditions = _asObjectMap(
      result.payload["conditions"],
    );
    expect(conditions.containsKey("rtt_bucket"), isFalse);
    expect(conditions.containsKey("quality"), isFalse);
    expect(conditions.containsKey("git_sha"), isFalse);

    final List<Object?> missingFields = _asObjectList(
      result.payload["missing_fields"],
    );
    expect(
      missingFields,
      <Object?>[
        "conditions.git_sha",
        "conditions.quality",
        "conditions.rtt_bucket",
      ],
    );
  });

  test("returns typed terminal oversize failure when timeline is empty", () {
    final List<SdkLogEntry> logs = <SdkLogEntry>[];
    final PackBuilder builder = PackBuilder(logger: logs.add);
    final PackBuildRequest request = PackBuildRequest(
      captureEnvelope: _envelope(timeline: const <TimelineEvent>[]),
      sessionId: _sessionId,
      maxPackBytesGzip: 1,
    );

    expect(
      () => builder.build(request),
      throwsA(
        isA<PackBuildFailure>().having(
          (PackBuildFailure failure) => failure.code,
          "code",
          PackBuildFailureCode.terminalOversize,
        ),
      ),
    );
    expect(logs, hasLength(1));
    expect(logs.single.code, SdkLogCodes.packBuildFailed);
    expect(logs.single.level, SdkLogLevel.error);
    expect(logs.single.metadata["capture_id"], "capture-1");
    expect(
      logs.single.metadata["failure_code"],
      PackBuildFailureCode.terminalOversize.name,
    );
    expect(logs.single.metadata["max_pack_bytes_gzip"], 1);
  });
}

const String _sessionId = "7f2c0a4b-3c1d-4b7e-9a20-8ddc4a9ef5c3";

CaptureEnvelope _envelope(
    {List<TimelineEvent> timeline = const <TimelineEvent>[]}) {
  return CaptureEnvelope(
    captureId: "capture-1",
    trigger: CaptureTrigger(
      type: "manual",
      reason: "user requested snapshot",
    ),
    triggerUtcMs: 1772323205123,
    triggerMonoMs: 121750,
    timeline: timeline,
  );
}

PackBuildRequest _request({
  required CaptureEnvelope envelope,
  required int maxPackBytesGzip,
}) {
  return PackBuildRequest(
    captureEnvelope: envelope,
    sessionId: _sessionId,
    appVersion: "1.3.0",
    build: "13045",
    deviceModel: "Pixel 8",
    osVersion: "Android 15",
    networkType: "wifi",
    maxPackBytesGzip: maxPackBytesGzip,
  );
}

Map<String, Object?> _asObjectMap(Object? value) {
  return Map<String, Object?>.from(value as Map<Object?, Object?>);
}

List<Object?> _asObjectList(Object? value) {
  return List<Object?>.from(value as List<Object?>);
}

int _timelineEventEncodedBytes(TimelineEvent event) {
  final List<String> keys = event.attributes.keys.toList()..sort();
  final Map<String, Object?> payload = <String, Object?>{
    "event_type": event.eventType,
    "t_mono_ms": event.tMonoMs,
  };
  for (final String key in keys) {
    payload[key] = event.attributes[key];
  }
  return utf8.encode(jsonEncode(payload)).length;
}

String _blob({required int seed, required int length}) {
  final StringBuffer buffer = StringBuffer();
  for (int index = 0; index < length; index += 1) {
    final int codeUnit = 97 + ((seed + (index * 17)) % 26);
    buffer.writeCharCode(codeUnit);
  }
  return buffer.toString();
}
