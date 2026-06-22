/// Privacy-safe diagnostics snapshot for the public Revclust facade.
final class RevclustDiagnostics {
  const RevclustDiagnostics({
    required this.bootstrap,
  });

  factory RevclustDiagnostics.notChecked({
    required Uri bootstrapOrigin,
  }) {
    return RevclustDiagnostics(
      bootstrap: RevclustBootstrapDiagnostics(
        state: RevclustBootstrapDiagnosticState.notChecked,
        bootstrapOrigin: bootstrapOrigin,
      ),
    );
  }

  /// Current best-known bootstrap diagnostics.
  final RevclustBootstrapDiagnostics bootstrap;
}

/// Privacy-safe bootstrap diagnostics.
final class RevclustBootstrapDiagnostics {
  const RevclustBootstrapDiagnostics({
    required this.state,
    required this.bootstrapOrigin,
    this.lastCheckedAt,
    this.lastHttpStatus,
    this.errorCategory,
    this.retryable,
    this.message,
  });

  /// Current best-known bootstrap state.
  final RevclustBootstrapDiagnosticState state;

  /// Safe origin only, never credentials, headers, body, or tokens.
  final Uri bootstrapOrigin;

  /// When this bootstrap state was last observed.
  final DateTime? lastCheckedAt;

  /// Last HTTP status when a response was observed.
  final int? lastHttpStatus;

  /// Coarse safe error category.
  final String? errorCategory;

  /// Whether retrying may reasonably recover.
  final bool? retryable;

  /// Partner-safe diagnostic message.
  final String? message;
}

/// Bootstrap states exposed through diagnostics.
enum RevclustBootstrapDiagnosticState {
  notChecked,
  ready,
  unavailable,
  misconfigured,
  notProvisioned,
  uploadBlocked,
}
