import "dart:collection";
import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "../capture/capture_envelope.dart";
import "../events/timeline_event.dart";
import "../observability/sdk_logger.dart";
import "pack_build_failure.dart";
import "pack_build_request.dart";
import "pack_build_result.dart";

/// Builds v1 pack payloads and gzip bytes with strict deterministic truncation.
class PackBuilder {
  PackBuilder({SdkLogger? logger}) : _logger = logger;

  static const String schemaVersion = "1.0.0";
  static const int defaultMaxPackBytesGzip = 512 * 1024;

  static const String _requiredUnknownPlaceholder = "unknown";

  static const Set<String> _validNetworkTypes = <String>{
    "wifi",
    "cellular",
    "offline",
    "unknown",
  };

  static final RegExp _gitShaPattern = RegExp(r"^[0-9a-f]{7,40}$");

  final SdkLogger? _logger;

  /// Build payload + gzip bytes and enforce max gzip cap via oldest-first drops.
  PackBuildResult build(PackBuildRequest request) {
    try {
      final _ResolvedConditions resolvedConditions =
          _resolveConditions(request);
      final Map<String, Object?> trigger =
          _buildTrigger(request.captureEnvelope);
      final Map<String, Object?> stateSnapshot = _buildStateSnapshot(request);
      final List<String> missingFields = List<String>.unmodifiable(
        resolvedConditions.missingFields.toList(growable: false),
      );

      final List<_TimelinePayloadEntry> timelineEntries = request
          .captureEnvelope.timeline
          .map((TimelineEvent event) => _toTimelinePayloadEntry(event))
          .toList(growable: true);

      bool truncated = false;
      int droppedBytes = 0;
      final SplayTreeMap<String, int> droppedCountsByType =
          SplayTreeMap<String, int>();

      int attempt = 0;
      final int maxAttempts = timelineEntries.length + 2;
      int lastAttemptedGzipBytes = 0;

      while (true) {
        attempt += 1;
        if (attempt > maxAttempts) {
          throw PackBuildFailure.loopGuardExceeded(
            maxPackBytesGzip: request.maxPackBytesGzip,
            attemptedGzipBytes: lastAttemptedGzipBytes,
            remainingTimelineEvents: timelineEntries.length,
            droppedBytes: droppedBytes,
          );
        }

        final Map<String, Object?> payload = _buildPayload(
          captureEnvelope: request.captureEnvelope,
          sessionId: request.sessionId,
          trigger: trigger,
          conditions: resolvedConditions.conditions,
          stateSnapshot: stateSnapshot,
          timelineEntries: timelineEntries,
          missingFields: missingFields,
          truncated: truncated,
          droppedCountsByType: droppedCountsByType,
          droppedBytes: droppedBytes,
        );
        final Uint8List gzipBytes = _gzipPayload(payload);
        lastAttemptedGzipBytes = gzipBytes.lengthInBytes;

        if (gzipBytes.lengthInBytes <= request.maxPackBytesGzip) {
          if (truncated) {
            _logger?.call(
              SdkLogEntry(
                level: SdkLogLevel.warning,
                code: SdkLogCodes.packTruncated,
                message:
                    "Pack build dropped oldest timeline events to stay within the gzip size cap.",
                metadata: <String, Object?>{
                  "capture_id": request.captureEnvelope.captureId,
                  "dropped_bytes": droppedBytes,
                  "dropped_counts_by_type": Map<String, int>.from(
                    droppedCountsByType,
                  ),
                  "dropped_event_count": droppedCountsByType.values.fold<int>(
                    0,
                    (int total, int count) => total + count,
                  ),
                  "max_pack_bytes_gzip": request.maxPackBytesGzip,
                },
              ),
            );
          }

          return PackBuildResult(
            payload: payload,
            gzipBytes: gzipBytes,
            truncated: truncated,
            droppedCountsByType: droppedCountsByType,
            droppedBytes: droppedBytes,
          );
        }

        if (timelineEntries.isEmpty) {
          throw PackBuildFailure.terminalOversize(
            maxPackBytesGzip: request.maxPackBytesGzip,
            attemptedGzipBytes: gzipBytes.lengthInBytes,
            remainingTimelineEvents: 0,
            droppedBytes: droppedBytes,
          );
        }

        final _TimelinePayloadEntry dropped = timelineEntries.removeAt(0);
        truncated = true;
        droppedBytes += dropped.byteSize;
        droppedCountsByType.update(
          dropped.eventType,
          (int count) => count + 1,
          ifAbsent: () => 1,
        );
      }
    } on PackBuildFailure catch (error, stackTrace) {
      _logger?.call(
        SdkLogEntry(
          level: SdkLogLevel.error,
          code: SdkLogCodes.packBuildFailed,
          message: "Pack build failed before an artifact could be emitted.",
          metadata: <String, Object?>{
            "attempted_gzip_bytes": error.attemptedGzipBytes,
            "capture_id": request.captureEnvelope.captureId,
            "dropped_bytes": error.droppedBytes,
            "failure_code": error.code.name,
            "max_pack_bytes_gzip": error.maxPackBytesGzip,
            "remaining_timeline_events": error.remainingTimelineEvents,
          },
          stackTrace: stackTrace,
        ),
      );
      rethrow;
    } catch (error, stackTrace) {
      _logger?.call(
        SdkLogEntry(
          level: SdkLogLevel.error,
          code: SdkLogCodes.packBuildFailed,
          message: "Pack build failed before an artifact could be emitted.",
          metadata: <String, Object?>{
            "capture_id": request.captureEnvelope.captureId,
            "error_type": error.runtimeType.toString(),
          },
          stackTrace: stackTrace,
        ),
      );
      rethrow;
    }
  }

  Map<String, Object?> _buildPayload({
    required CaptureEnvelope captureEnvelope,
    required String sessionId,
    required Map<String, Object?> trigger,
    required Map<String, Object?> conditions,
    required Map<String, Object?> stateSnapshot,
    required List<_TimelinePayloadEntry> timelineEntries,
    required List<String> missingFields,
    required bool truncated,
    required Map<String, int> droppedCountsByType,
    required int droppedBytes,
  }) {
    return <String, Object?>{
      "schema_version": schemaVersion,
      "capture_id": captureEnvelope.captureId,
      "session_id": sessionId,
      "trigger": trigger,
      "conditions": conditions,
      "timeline": timelineEntries
          .map((_TimelinePayloadEntry entry) => entry.payload)
          .toList(growable: false),
      "state_snapshot": stateSnapshot,
      "missing_fields": missingFields,
      "truncation": <String, Object?>{
        "truncated": truncated,
        "dropped_counts_by_type": Map<String, int>.from(droppedCountsByType),
        "dropped_bytes": droppedBytes,
      },
    };
  }

  Map<String, Object?> _buildTrigger(CaptureEnvelope captureEnvelope) {
    final Map<String, Object?> triggerPayload = <String, Object?>{
      "type": captureEnvelope.trigger.type,
      "trigger_utc_ms": captureEnvelope.triggerUtcMs,
      "trigger_mono_ms": captureEnvelope.triggerMonoMs,
    };
    if (captureEnvelope.trigger.reason != null) {
      triggerPayload["reason"] = captureEnvelope.trigger.reason;
    }
    final List<String> attributeKeys = captureEnvelope.trigger.attributes.keys
        .where((String key) => !triggerPayload.containsKey(key))
        .toList(growable: false)
      ..sort((String a, String b) => a.compareTo(b));
    for (final String key in attributeKeys) {
      triggerPayload[key] = _canonicalizeJson(
        captureEnvelope.trigger.attributes[key],
      );
    }

    if (captureEnvelope.trigger.expected != null) {
      triggerPayload["expected"] = _canonicalizeJson(
        captureEnvelope.trigger.expected,
      );
    }
    if (captureEnvelope.trigger.observed != null) {
      triggerPayload["observed"] = _canonicalizeJson(
        captureEnvelope.trigger.observed,
      );
    }
    if (captureEnvelope.trigger.signature != null) {
      triggerPayload["signature"] = captureEnvelope.trigger.signature;
    }
    return Map<String, Object?>.unmodifiable(triggerPayload);
  }

  Map<String, Object?> _buildStateSnapshot(PackBuildRequest request) {
    return Map<String, Object?>.unmodifiable(<String, Object?>{
      "app_state": _canonicalizeObjectMap(
        request.appState ?? const <String, Object?>{},
      ),
      "data_state": _canonicalizeObjectMap(
        request.dataState ?? const <String, Object?>{},
      ),
    });
  }

  _ResolvedConditions _resolveConditions(PackBuildRequest request) {
    final SplayTreeSet<String> missingFields = SplayTreeSet<String>();
    final String? normalizedRttBucket = _normalizeOptionalNonEmpty(
      request.rttBucket,
    );
    final String? normalizedQuality =
        _normalizeOptionalNonEmpty(request.quality);
    final String? normalizedGitSha = _normalizeGitSha(request.gitSha);
    final String? normalizedAppReleaseStage =
        _normalizeOptionalNonEmpty(request.appReleaseStage);

    if (normalizedRttBucket == null) {
      missingFields.add("conditions.rtt_bucket");
    }
    if (normalizedQuality == null) {
      missingFields.add("conditions.quality");
    }
    if (normalizedGitSha == null) {
      missingFields.add("conditions.git_sha");
    }

    final Map<String, Object?> conditions = <String, Object?>{
      "app_version": _requiredOrUnknown(request.appVersion),
      "build": _requiredOrUnknown(request.build),
      "device_model": _requiredOrUnknown(request.deviceModel),
      "os_version": _requiredOrUnknown(request.osVersion),
      "network_type": _normalizeNetworkType(request.networkType),
      "update_context": <String, Object?>{
        "is_first_run_after_update":
            request.updateContextSnapshot.isFirstRunAfterUpdate,
        "prev_app_version": _normalizeOptionalNonEmpty(
            request.updateContextSnapshot.prevAppVersion),
        "install_type": request.updateContextSnapshot.installType,
      },
    };

    if (normalizedRttBucket != null) {
      conditions["rtt_bucket"] = normalizedRttBucket;
    }
    if (normalizedQuality != null) {
      conditions["quality"] = normalizedQuality;
    }
    if (normalizedGitSha != null) {
      conditions["git_sha"] = normalizedGitSha;
    }
    if (normalizedAppReleaseStage != null) {
      conditions["app_release_stage"] = normalizedAppReleaseStage;
    }

    return _ResolvedConditions(
      conditions: Map<String, Object?>.unmodifiable(conditions),
      missingFields: missingFields,
    );
  }

  _TimelinePayloadEntry _toTimelinePayloadEntry(TimelineEvent event) {
    final Map<String, Object?> payload = <String, Object?>{
      "event_type": event.eventType,
      "t_mono_ms": event.tMonoMs,
    };

    final List<String> attributeKeys = event.attributes.keys.toList()
      ..sort((String a, String b) => a.compareTo(b));
    for (final String key in attributeKeys) {
      payload[key] = _canonicalizeJson(event.attributes[key]);
    }

    final int byteSize = utf8.encode(jsonEncode(payload)).length;
    return _TimelinePayloadEntry(
      eventType: event.eventType,
      payload: Map<String, Object?>.unmodifiable(payload),
      byteSize: byteSize,
    );
  }

  String _requiredOrUnknown(String? value) {
    final String? normalized = _normalizeOptionalNonEmpty(value);
    return normalized ?? _requiredUnknownPlaceholder;
  }

  String _normalizeNetworkType(String? value) {
    final String? normalized = _normalizeOptionalNonEmpty(value)?.toLowerCase();
    if (normalized == null || !_validNetworkTypes.contains(normalized)) {
      return _requiredUnknownPlaceholder;
    }
    return normalized;
  }

  String? _normalizeGitSha(String? value) {
    final String? normalized = _normalizeOptionalNonEmpty(value)?.toLowerCase();
    if (normalized == null) {
      return null;
    }
    if (_gitShaPattern.hasMatch(normalized)) {
      return normalized;
    }
    return null;
  }

  String? _normalizeOptionalNonEmpty(String? value) {
    if (value == null) {
      return null;
    }
    final String normalized = value.trim();
    if (normalized.isEmpty) {
      return null;
    }
    return normalized;
  }

  Map<String, Object?> _canonicalizeObjectMap(Map<String, Object?> source) {
    final List<String> keys = source.keys.toList()
      ..sort((String a, String b) => a.compareTo(b));
    final Map<String, Object?> canonicalized = <String, Object?>{};
    for (final String key in keys) {
      canonicalized[key] = _canonicalizeJson(source[key]);
    }
    return Map<String, Object?>.unmodifiable(canonicalized);
  }

  Object? _canonicalizeJson(Object? value) {
    if (value is Map<Object?, Object?>) {
      final List<MapEntry<Object?, Object?>> entries = value.entries.toList()
        ..sort(
          (MapEntry<Object?, Object?> a, MapEntry<Object?, Object?> b) =>
              a.key.toString().compareTo(b.key.toString()),
        );
      final Map<String, Object?> canonicalizedMap = <String, Object?>{};
      for (final MapEntry<Object?, Object?> entry in entries) {
        canonicalizedMap[entry.key.toString()] = _canonicalizeJson(entry.value);
      }
      return Map<String, Object?>.unmodifiable(canonicalizedMap);
    }

    if (value is Iterable<Object?>) {
      return value.map(_canonicalizeJson).toList(growable: false);
    }

    return value;
  }

  Uint8List _gzipPayload(Map<String, Object?> payload) {
    final List<int> jsonBytes = utf8.encode(jsonEncode(payload));
    final List<int> gzipBytes = GZipCodec().encode(jsonBytes);
    return Uint8List.fromList(gzipBytes);
  }
}

class _TimelinePayloadEntry {
  _TimelinePayloadEntry({
    required this.eventType,
    required this.payload,
    required this.byteSize,
  });

  final String eventType;
  final Map<String, Object?> payload;
  final int byteSize;
}

class _ResolvedConditions {
  _ResolvedConditions({
    required this.conditions,
    required this.missingFields,
  });

  final Map<String, Object?> conditions;
  final SplayTreeSet<String> missingFields;
}
