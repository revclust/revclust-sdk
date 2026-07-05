/// Coarse Revclust service-health state.
enum RevclustStatus {
  disabled,
  initializing,
  ready,
  degraded,
  misconfigured,
  notProvisioned,
  uploadBlocked,
}
