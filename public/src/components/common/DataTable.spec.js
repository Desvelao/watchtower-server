import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mount } from "@vue/test-utils";
import DataTable from "./DataTable.vue";
import PaginationControls from "./PaginationControls.vue";

const COLUMNS = [
  { key: "id", label: "ID", sortable: true },
  { key: "status", label: "Status", sortable: true },
  { key: "tags", label: "Tags" },
];

const ITEMS = [
  { id: 1, status: "pending", tags: ["a", "b"] },
  { id: 2, status: "acknowledged", tags: [] },
];

const OTHER_FIELDS = [{ key: "status", label: "Status" }];

const GLOBAL_STUBS = { global: { stubs: { PaginationControls: true, TableFilterBar: true, IconRefresh: true } } };

function mountTable(props = {}) {
  return mount(DataTable, {
    props: { columns: COLUMNS, items: ITEMS, ...props },
    ...GLOBAL_STUBS,
  });
}

describe("DataTable", () => {
  describe("sorting", () => {
    it("does not emit update:sort when clicking a non-sortable column header", async () => {
      const wrapper = mountTable();
      const headers = wrapper.findAll("th");
      const tagsHeader = headers.find((h) => h.text().includes("Tags"));
      await tagsHeader.trigger("click");
      expect(wrapper.emitted("update:sort")).toBeUndefined();
    });

    it("defaults to ascending on a newly-sorted column", async () => {
      const wrapper = mountTable();
      const headers = wrapper.findAll("th");
      const idHeader = headers.find((h) => h.text().includes("ID"));
      await idHeader.trigger("click");
      expect(wrapper.emitted("update:sort")).toEqual([["id:asc"]]);
    });

    it("toggles asc -> desc when clicking the already-active sorted column", async () => {
      const wrapper = mountTable({ sort: "id:asc" });
      const headers = wrapper.findAll("th");
      const idHeader = headers.find((h) => h.text().includes("ID"));
      await idHeader.trigger("click");
      expect(wrapper.emitted("update:sort")).toEqual([["id:desc"]]);
    });

    it("defaults to asc when switching the active sort to a different column", async () => {
      const wrapper = mountTable({ sort: "id:asc" });
      const headers = wrapper.findAll("th");
      const statusHeader = headers.find((h) => h.text().includes("Status"));
      await statusHeader.trigger("click");
      expect(wrapper.emitted("update:sort")).toEqual([["status:asc"]]);
    });
  });

  describe("click-to-filter", () => {
    it("wraps a filterable single-value cell in a button that emits update:filters", async () => {
      const wrapper = mountTable({ otherFields: OTHER_FIELDS });
      const statusButtons = wrapper.findAll("td button");
      expect(statusButtons.length).toBeGreaterThan(0);
      await statusButtons[0].trigger("click");
      expect(wrapper.emitted("update:filters")).toEqual([[{ status: "pending" }]]);
    });

    it("does not wrap an array-valued cell in a filter button even if the column is in otherFields", () => {
      const wrapper = mountTable({ otherFields: [...OTHER_FIELDS, { key: "tags", label: "Tags" }] });
      // only the status column (single value) should produce a button; tags (array) must not
      const buttons = wrapper.findAll("td button");
      expect(buttons).toHaveLength(ITEMS.length); // one per row, for status only
    });

    it("does not wrap a cell whose column key is absent from otherFields", () => {
      const wrapper = mountTable({ otherFields: [] });
      expect(wrapper.findAll("td button")).toHaveLength(0);
    });
  });

  describe("loading / empty states", () => {
    it("renders a single spanning row while loading", () => {
      const wrapper = mountTable({ loading: true });
      const rows = wrapper.findAll("tbody tr");
      expect(rows).toHaveLength(1);
      expect(rows[0].text()).toContain("Loading...");
      expect(rows[0].find("td").attributes("colspan")).toBe(String(COLUMNS.length));
    });

    it("renders a single spanning row with emptyText when there are no items", () => {
      const wrapper = mountTable({ items: [], emptyText: "Nothing here" });
      const rows = wrapper.findAll("tbody tr");
      expect(rows).toHaveLength(1);
      expect(rows[0].text()).toContain("Nothing here");
    });
  });

  describe("selection", () => {
    it("shows the bulk-actions bar once a row is selected, and updates the selected count", async () => {
      const wrapper = mountTable({ selectable: true });
      expect(wrapper.text()).not.toContain("selected");

      const rowCheckbox = wrapper.find('tbody input[type=checkbox]');
      await rowCheckbox.setValue(true);

      expect(wrapper.text()).toContain("1 selected");
    });

    it("resets the selection when the items array reference changes", async () => {
      const wrapper = mountTable({ selectable: true });
      const rowCheckbox = wrapper.find("tbody input[type=checkbox]");
      await rowCheckbox.setValue(true);
      expect(wrapper.text()).toContain("1 selected");

      await wrapper.setProps({ items: [...ITEMS] }); // new array reference, same content
      await wrapper.vm.$nextTick();

      expect(wrapper.text()).not.toContain("selected");
    });
  });

  describe("pagination", () => {
    it("does not render PaginationControls when pagination is not provided", () => {
      const wrapper = mountTable();
      expect(wrapper.findComponent(PaginationControls).exists()).toBe(false);
    });

    it("renders PaginationControls when pagination is provided", () => {
      const wrapper = mountTable({ pagination: { from: 0, size: 20 }, totalItems: 2 });
      expect(wrapper.findComponent(PaginationControls).exists()).toBe(true);
    });
  });

  describe("auto-refresh", () => {
    beforeEach(() => {
      vi.useFakeTimers();
      localStorage.clear();
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    it("defaults the interval select to Off and never emits refresh purely from elapsed time", () => {
      const wrapper = mountTable();
      const select = wrapper.find('select[aria-label="Auto-refresh interval"]');
      expect(select.element.value).toBe("0");

      vi.advanceTimersByTime(5 * 60 * 1000);
      expect(wrapper.emitted("refresh")).toBeUndefined();
    });

    it("emits refresh after the selected interval elapses", async () => {
      const wrapper = mountTable();
      const select = wrapper.find('select[aria-label="Auto-refresh interval"]');
      await select.setValue("10000");

      vi.advanceTimersByTime(10000);
      expect(wrapper.emitted("refresh")).toHaveLength(1);
    });

    it("does not emit refresh while loading, but does once loading flips back to false", async () => {
      const wrapper = mountTable({ loading: true });
      const select = wrapper.find('select[aria-label="Auto-refresh interval"]');
      await select.setValue("10000");

      vi.advanceTimersByTime(10000);
      expect(wrapper.emitted("refresh")).toBeUndefined();

      await wrapper.setProps({ loading: false });
      vi.advanceTimersByTime(10000);
      expect(wrapper.emitted("refresh")).toHaveLength(1);
    });

    it("stops ticking after unmount without throwing", async () => {
      const wrapper = mountTable();
      const select = wrapper.find('select[aria-label="Auto-refresh interval"]');
      await select.setValue("10000");

      wrapper.unmount();
      expect(() => vi.advanceTimersByTime(60000)).not.toThrow();
    });
  });
});
