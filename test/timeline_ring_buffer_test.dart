import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter_sdk/src/internal/revclust_internal.dart";

void main() {
  test("evicts oldest first when max events cap is exceeded", () {
    final TimelineRingBuffer buffer = TimelineRingBuffer(
      maxEvents: 3,
      maxBytes: 100000,
    );

    buffer.add(_event("e1", 1000));
    buffer.add(_event("e2", 2000));
    buffer.add(_event("e3", 3000));
    buffer.add(_event("e4", 4000));

    expect(_eventTypes(buffer.snapshot), <String>["e2", "e3", "e4"]);
    expect(buffer.length, 3);
  });

  test("evicts oldest first until max bytes cap is satisfied", () {
    final TimelineEvent e1 = _event(
      "a1",
      10,
      attributes: const <String, Object?>{"payload": "1234567890"},
    );
    final TimelineEvent e2 = _event(
      "b2",
      10,
      attributes: const <String, Object?>{"payload": "1234567890"},
    );
    final TimelineEvent e3 = _event(
      "c3",
      10,
      attributes: const <String, Object?>{"payload": "1234567890"},
    );
    final int singleSize = e1.estimatedByteSize;

    expect(e2.estimatedByteSize, singleSize);
    expect(e3.estimatedByteSize, singleSize);

    final TimelineRingBuffer buffer = TimelineRingBuffer(
      maxEvents: 10,
      maxBytes: singleSize * 2,
    );

    buffer.add(e1);
    buffer.add(e2);
    buffer.add(e3);

    expect(_eventTypes(buffer.snapshot), <String>["b2", "c3"]);
    expect(buffer.estimatedBytes, singleSize * 2);
  });

  test("enforces event and byte caps after each insertion", () {
    final TimelineEvent prototype = _event(
      "aa",
      0,
      attributes: const <String, Object?>{"payload": "fixed"},
    );
    final int singleSize = prototype.estimatedByteSize;
    final int maxBytes = singleSize * 2;

    final TimelineRingBuffer buffer = TimelineRingBuffer(
      maxEvents: 2,
      maxBytes: maxBytes,
    );

    final List<TimelineEvent> events = <TimelineEvent>[
      _event("e1", 0, attributes: const <String, Object?>{"payload": "fixed"}),
      _event("e2", 1, attributes: const <String, Object?>{"payload": "fixed"}),
      _event("e3", 2, attributes: const <String, Object?>{"payload": "fixed"}),
      _event("e4", 3, attributes: const <String, Object?>{"payload": "fixed"}),
    ];

    for (final TimelineEvent event in events) {
      buffer.add(event);
      expect(buffer.length <= 2, isTrue);
      expect(buffer.estimatedBytes <= maxBytes, isTrue);
    }

    expect(_eventTypes(buffer.snapshot), <String>["e3", "e4"]);
  });

  test("preserves insertion order when tMonoMs values are equal", () {
    final TimelineRingBuffer buffer = TimelineRingBuffer(
      maxEvents: 3,
      maxBytes: 100000,
    );
    const int tMonoMs = 12345;

    buffer.add(_event("first", tMonoMs));
    buffer.add(_event("second", tMonoMs));
    buffer.add(_event("third", tMonoMs));
    buffer.add(_event("fourth", tMonoMs));

    expect(_eventTypes(buffer.snapshot), <String>["second", "third", "fourth"]);
  });

  test("same input sequence produces same snapshot and byte count", () {
    final TimelineRingBuffer left = TimelineRingBuffer(
      maxEvents: 4,
      maxBytes: 1000,
    );
    final TimelineRingBuffer right = TimelineRingBuffer(
      maxEvents: 4,
      maxBytes: 1000,
    );

    final List<TimelineEvent> sequence = <TimelineEvent>[
      _event("a", 2),
      _event("b", 0),
      _event("c", 0, attributes: const <String, Object?>{"k": "v"}),
      _event("d", 1),
      _event("e", 3, attributes: const <String, Object?>{"payload": "123456"}),
    ];

    for (final TimelineEvent event in sequence) {
      left.add(event);
      right.add(event);
    }

    expect(_signatures(left.snapshot), _signatures(right.snapshot));
    expect(left.estimatedBytes, right.estimatedBytes);
  });

  test("rejects invalid ring buffer caps", () {
    expect(
      () => TimelineRingBuffer(maxEvents: 0, maxBytes: 1),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => TimelineRingBuffer(maxEvents: 1, maxBytes: 0),
      throwsA(isA<ArgumentError>()),
    );
  });
}

TimelineEvent _event(
  String eventType,
  int tMonoMs, {
  Map<String, Object?> attributes = const <String, Object?>{},
}) {
  return TimelineEvent(
    eventType: eventType,
    tMonoMs: tMonoMs,
    attributes: attributes,
  );
}

List<String> _eventTypes(List<TimelineEvent> events) {
  return events.map((TimelineEvent event) => event.eventType).toList();
}

List<String> _signatures(List<TimelineEvent> events) {
  return events
      .map(
        (TimelineEvent event) =>
            "${event.eventType}:${event.tMonoMs}:${event.estimatedByteSize}",
      )
      .toList();
}
