// The API returns Postgres TIMESTAMP (no time zone) values as bare
// "YYYY-MM-DD HH:MM:SS[.ffffff]" strings. That's actually UTC wall-clock
// time (the db has no TZ set), but without an offset marker JS parses
// space-separated date strings as local time, silently shifting every
// displayed timestamp by the browser's UTC offset. Normalize to an
// explicit UTC ISO string before handing it to Date so toLocaleString()
// converts it correctly into the viewer's local timezone.
function toUtcIso(value) {
  if (/[zZ]|[+-]\d{2}:?\d{2}$/.test(value)) return value;
  return value.replace(" ", "T").replace(/(\.\d{3})\d*$/, "$1") + "Z";
}

// Parses a server timestamp (bare-UTC string, or already-offset ISO) into a
// real Date, applying the same UTC normalization formatDate uses - shared so
// any caller needing an actual Date (not just a display string), e.g. for
// bucketing/axis math, stays consistent with how dates render elsewhere.
export function parseServerDate(value) {
  if (!value) return null;
  return new Date(toUtcIso(value));
}

export function formatDate(value) {
  if (!value) return "-";
  return new Date(toUtcIso(value)).toLocaleString(undefined, { hour12: false });
}

// Write-side mirror of toUtcIso above: a <input type="datetime-local">
// value is local wall-clock with no zone marker, while created_at filters
// compare against a bare-UTC-wall-clock column - sending the local value
// straight through would silently compare local time against UTC for any
// viewer not in UTC. Parses it as local time, then re-renders the UTC
// wall-clock components as the same bare "YYYY-MM-DD HH:MM:SS" shape the
// server already stores/expects.
export function localDateTimeToServerParam(value) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  const pad = (n) => String(n).padStart(2, "0");
  return (
    `${date.getUTCFullYear()}-${pad(date.getUTCMonth() + 1)}-${pad(date.getUTCDate())} ` +
    `${pad(date.getUTCHours())}:${pad(date.getUTCMinutes())}:${pad(date.getUTCSeconds())}`
  );
}

// `minutes` ago, formatted for direct use as a <input type="datetime-local">
// value (local wall-clock) - the building block for every time-range
// filter preset (see DATE_RANGE_PRESETS / components/common/DateRangeFilter.vue).
export function minutesAgoLocalDateTime(minutes) {
  const d = new Date(Date.now() - minutes * 60 * 1000);
  const pad = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function hoursAgoLocalDateTime(hours) {
  return minutesAgoLocalDateTime(hours * 60);
}

const RELATIVE_DATE_PATTERN = /^now(?:-(\d+)([mhd]))?$/;
const UNIT_MINUTES = { m: 1, h: 60, d: 1440 };

// True for "now" / "now-<N>m" / "now-<N>h" / "now-<N>d" - relative date
// keywords the SERVER resolves fresh on every request (see
// helpers/db.lua's resolve_relative_date, kept in sync with this pattern).
// These must never be run through localDateTimeToServerParam - they aren't
// local wall-clock values, they're literal keywords the backend interprets
// against its own current time, which is what keeps a preset (or the
// default range) from going stale between the moment it was picked and
// whenever the request actually runs.
export function isRelativeDateKeyword(value) {
  return typeof value === "string" && RELATIVE_DATE_PATTERN.test(value);
}

// Builds the keyword for "<amount> <unit> ago" (or exactly "now" for a
// falsy amount). `unit` is "m"/"h"/"d", defaulting to "h" so every
// pre-existing hours-only call site keeps working unchanged.
export function relativeDateKeyword(amount, unit = "h") {
  return amount ? `now-${amount}${unit}` : "now";
}

// Best-effort CLIENT-SIDE approximation of what a relative keyword resolves
// to right now, used only to pre-fill the custom-range popover's
// datetime-local inputs when switching away from an active preset - actual
// filtering always re-resolves server-side regardless of what this shows.
export function relativeDateKeywordToLocalDateTime(value) {
  const match = RELATIVE_DATE_PATTERN.exec(value);
  if (!match) return "";
  const minutes = match[1] ? Number(match[1]) * UNIT_MINUTES[match[2]] : 0;
  return minutesAgoLocalDateTime(minutes);
}

// Human label for a relative keyword that doesn't exactly match a
// configured preset (e.g. a hand-edited deep link like "now-3h") - used
// instead of falling into DateRangeFilter's raw custom-range formatter,
// which would otherwise show the keyword text verbatim.
export function relativeDateKeywordLabel(value) {
  const match = RELATIVE_DATE_PATTERN.exec(value);
  if (!match) return null;
  if (!match[1]) return "Now";
  return `Last ${match[1]}${match[2]}`;
}

// Shared preset list for DateRangeFilter.vue - every preset is an open
// lower bound only (empty upper bound), so results keep updating live
// rather than freezing at the moment the preset was picked.
export const DATE_RANGE_PRESETS = [
  { key: "1h", label: "Last 1h", hours: 1 },
  { key: "2h", label: "Last 2h", hours: 2 },
  { key: "6h", label: "Last 6h", hours: 6 },
  { key: "12h", label: "Last 12h", hours: 12 },
  { key: "24h", label: "Last 24h", hours: 24 },
  { key: "2d", label: "Last 2 days", hours: 48 },
  { key: "7d", label: "Last 7 days", hours: 24 * 7 },
  { key: "30d", label: "Last 30 days", hours: 24 * 30 },
  { key: "60d", label: "Last 60 days", hours: 24 * 60 },
  { key: "90d", label: "Last 90 days", hours: 24 * 90 },
];

export function formatUptime(seconds) {
  if (seconds === null || seconds === undefined) return "—";
  const s = Math.floor(seconds);
  const days = Math.floor(s / 86400);
  const hours = Math.floor((s % 86400) / 3600);
  const minutes = Math.floor((s % 3600) / 60);
  if (days > 0) return `${days}d ${hours}h`;
  if (hours > 0) return `${hours}h ${minutes}m`;
  return `${minutes}m`;
}
