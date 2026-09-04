// Single source of truth for the alert priority -> color tone mapping,
// shared by AlertPriorityBadge and the dashboard's stat tiles so the
// severity color scheme stays consistent across the app.
export const PRIORITY_TONES = {
  low: "slate",
  medium: "blue",
  high: "orange",
  critical: "red",
};
