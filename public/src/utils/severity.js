// Single source of truth for the alert severity -> color tone mapping,
// shared by AlertSeverityBadge and the dashboard's stat tiles so the
// severity color scheme stays consistent across the app.
export const SEVERITY_TONES = {
  low: "slate",
  medium: "blue",
  high: "orange",
  critical: "red",
};
