import "_validation.dart";

/// Minimal hosted-first bootstrap configuration for the public Revclust facade.
final class RevclustConfig {
  /// Creates the partner-facing bootstrap config.
  RevclustConfig({
    required String projectKey,
    this.environment = RevclustEnvironment.production,
  }) : projectKey = normalizeRequiredString(projectKey, "projectKey");

  /// Publishable bootstrap key used for hosted bootstrap:
  /// `rpk_` plus a 32-character unpadded base64url body.
  final String projectKey;

  /// Optional environment target when the backend model needs one.
  final RevclustEnvironment environment;

  @override
  bool operator ==(Object other) {
    return other is RevclustConfig &&
        other.projectKey == projectKey &&
        other.environment == environment;
  }

  @override
  int get hashCode => Object.hash(projectKey, environment);
}

/// Small environment selector for the hosted public facade.
enum RevclustEnvironment {
  production,
  staging,
  development,
}
