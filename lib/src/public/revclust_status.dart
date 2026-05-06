/// Coarse service-health state for the hosted-first public facade.
enum RevclustStatus {
  disabled,
  initializing,
  ready,
  degraded,
  misconfigured,
  notProvisioned,
  uploadBlocked,
}
