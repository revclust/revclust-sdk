import "_validation.dart";

/// Revclust SDK configuration.
final class RevclustConfig {
  /// Creates Revclust SDK configuration.
  RevclustConfig({
    required String projectKey,
    this.releaseStage,
    String? appVersion,
    String? build,
    String? gitSha,
  })  : projectKey = normalizeRequiredString(projectKey, "projectKey"),
        appVersion = normalizeOptionalString(appVersion, "appVersion"),
        build = normalizeOptionalString(build, "build"),
        gitSha = _normalizeOptionalGitSha(gitSha, "gitSha");

  /// Publishable bootstrap key used for hosted bootstrap:
  /// `rpk_` plus a 32-character unpadded base64url body.
  final String projectKey;

  /// Optional app release stage metadata attached to captured packs.
  ///
  /// This describes the app build that produced a capture. It does not
  /// select Revclust infrastructure.
  final RevclustAppReleaseStage? releaseStage;

  /// Optional app version attached to captured pack conditions.
  final String? appVersion;

  /// Optional app build identifier attached to captured pack conditions.
  final String? build;

  /// Optional source revision attached to captured pack conditions.
  final String? gitSha;

  @override
  bool operator ==(Object other) {
    return other is RevclustConfig &&
        other.projectKey == projectKey &&
        other.releaseStage == releaseStage &&
        other.appVersion == appVersion &&
        other.build == build &&
        other.gitSha == gitSha;
  }

  @override
  int get hashCode =>
      Object.hash(projectKey, releaseStage, appVersion, build, gitSha);

  static final RegExp _gitShaPattern = RegExp(r"^[0-9a-f]{7,40}$");

  static String? _normalizeOptionalGitSha(String? value, String name) {
    final String? normalized =
        normalizeOptionalString(value, name)?.toLowerCase();
    if (normalized == null) {
      return null;
    }
    if (!_gitShaPattern.hasMatch(normalized)) {
      throw ArgumentError.value(
          value, name, "must be a 7-40 character hex SHA");
    }
    return normalized;
  }
}

/// App release-stage metadata.
final class RevclustAppReleaseStage {
  const RevclustAppReleaseStage._(this.value);

  factory RevclustAppReleaseStage.custom(String value) {
    final String normalized = value.trim();
    if (!_releaseStagePattern.hasMatch(normalized)) {
      throw ArgumentError(
        "release stage must match ^[a-z0-9_-]{1,32}\$",
      );
    }
    return RevclustAppReleaseStage._(normalized);
  }

  static const RevclustAppReleaseStage development =
      RevclustAppReleaseStage._("development");
  static const RevclustAppReleaseStage staging =
      RevclustAppReleaseStage._("staging");
  static const RevclustAppReleaseStage production =
      RevclustAppReleaseStage._("production");
  static const RevclustAppReleaseStage test = RevclustAppReleaseStage._("test");

  static final RegExp _releaseStagePattern = RegExp(r"^[a-z0-9_-]{1,32}$");

  /// Safe app-stage value attached to captured packs.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is RevclustAppReleaseStage && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
