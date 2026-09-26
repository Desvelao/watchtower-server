import { afterEach, describe, expect, it } from "vitest";
import { formatDate } from "./date";

const originalTz = process.env.TZ;

afterEach(() => {
  if (originalTz === undefined) delete process.env.TZ;
  else process.env.TZ = originalTz;
});

// 2026-09-19 14:03:22 UTC, rendered the way formatDate must: the browser's
// own timezone/locale.
const instant = new Date(Date.UTC(2026, 8, 19, 14, 3, 22));
const expected = instant.toLocaleString(undefined, { hour12: false });

describe("formatDate", () => {
  it("treats a bare server timestamp as UTC and renders it in local time", () => {
    expect(formatDate("2026-09-19 14:03:22")).toBe(expected);
    expect(formatDate("2026-09-19 14:03:22.123456")).toBe(expected);
  });

  it("accepts ISO strings with a Z or an explicit offset", () => {
    expect(formatDate("2026-09-19T14:03:22Z")).toBe(expected);
    expect(formatDate("2026-09-19T16:03:22+02:00")).toBe(expected);
  });

  it("accepts a real Date", () => {
    expect(formatDate(instant)).toBe(expected);
  });

  it("converts into the browser timezone rather than passing UTC through", () => {
    process.env.TZ = "Asia/Tokyo";
    expect(formatDate("2026-09-19 00:00:00")).toContain("09:00:00");
    process.env.TZ = "America/New_York";
    expect(formatDate("2026-09-19 00:00:00")).toContain("20:00:00");
  });

  it("returns '-' for empty or invalid input", () => {
    expect(formatDate(null)).toBe("-");
    expect(formatDate("")).toBe("-");
    expect(formatDate("not a date")).toBe("-");
  });
});
