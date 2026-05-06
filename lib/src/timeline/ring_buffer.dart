import "../events/timeline_event.dart";

/// In-memory timeline buffer with deterministic oldest-first eviction.
class TimelineRingBuffer {
  /// Creates a ring buffer with explicit event and byte caps.
  TimelineRingBuffer({required this.maxEvents, required this.maxBytes}) {
    if (maxEvents <= 0) {
      throw ArgumentError.value(maxEvents, "maxEvents", "must be > 0");
    }
    if (maxBytes <= 0) {
      throw ArgumentError.value(maxBytes, "maxBytes", "must be > 0");
    }
  }

  /// Maximum retained event count.
  final int maxEvents;

  /// Maximum retained estimated bytes.
  final int maxBytes;

  final List<_BufferedEvent> _events = <_BufferedEvent>[];
  int _nextInsertionSequence = 0;
  int _estimatedBytes = 0;

  /// Current retained event count.
  int get length => _events.length;

  /// Current retained approximate byte count.
  int get estimatedBytes => _estimatedBytes;

  /// Returns an immutable snapshot in buffer order.
  List<TimelineEvent> get snapshot => List<TimelineEvent>.unmodifiable(
        _events.map((_BufferedEvent buffered) => buffered.event),
      );

  /// Adds an event and evicts oldest entries until all caps are satisfied.
  void add(TimelineEvent event) {
    final _BufferedEvent buffered = _BufferedEvent(
      event: event,
      insertionSequence: _nextInsertionSequence,
      estimatedBytes: event.estimatedByteSize,
    );
    _nextInsertionSequence += 1;

    _events.insert(_findInsertionIndex(buffered), buffered);
    _estimatedBytes += buffered.estimatedBytes;

    _evictUntilWithinCaps();
  }

  int _findInsertionIndex(_BufferedEvent candidate) {
    int low = 0;
    int high = _events.length;
    while (low < high) {
      final int mid = low + ((high - low) >> 1);
      if (_compare(_events[mid], candidate) <= 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  int _compare(_BufferedEvent left, _BufferedEvent right) {
    final int byMonotonicTime = left.event.tMonoMs.compareTo(
      right.event.tMonoMs,
    );
    if (byMonotonicTime != 0) {
      return byMonotonicTime;
    }
    return left.insertionSequence.compareTo(right.insertionSequence);
  }

  void _evictUntilWithinCaps() {
    while (_events.length > maxEvents || _estimatedBytes > maxBytes) {
      final _BufferedEvent removed = _events.removeAt(0);
      _estimatedBytes -= removed.estimatedBytes;
    }
  }
}

class _BufferedEvent {
  const _BufferedEvent({
    required this.event,
    required this.insertionSequence,
    required this.estimatedBytes,
  });

  final TimelineEvent event;
  final int insertionSequence;
  final int estimatedBytes;
}
