import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mount } from "@vue/test-utils";
import TableFilterBar from "./TableFilterBar.vue";
import DateRangeFilter from "./DateRangeFilter.vue";

const TEXT_FIELD = { key: "name", label: "Name", type: "text" };
const SELECT_FIELD = {
  key: "status",
  label: "Status",
  type: "select",
  options: [
    { value: "", label: "All" },
    { value: "pending", label: "Pending" },
  ],
};

describe("TableFilterBar", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("debounces a text field's input before emitting update:filters", async () => {
    const wrapper = mount(TableFilterBar, {
      props: { filters: { name: "" }, otherFields: [TEXT_FIELD] },
    });

    const input = wrapper.find("#filter-name");
    await input.setValue("abc");

    expect(wrapper.emitted("update:filters")).toBeUndefined();

    vi.advanceTimersByTime(399);
    expect(wrapper.emitted("update:filters")).toBeUndefined();

    vi.advanceTimersByTime(1);
    expect(wrapper.emitted("update:filters")).toEqual([[{ name: "abc" }]]);
  });

  it("does not clobber an in-flight field when the external filters prop changes mid-typing", async () => {
    const wrapper = mount(TableFilterBar, {
      props: { filters: { name: "" }, otherFields: [TEXT_FIELD] },
    });

    const input = wrapper.find("#filter-name");
    await input.setValue("typing");

    // external update arrives before the debounce fires (e.g. a badge-click
    // filter elsewhere) - the field being edited must keep the user's value
    await wrapper.setProps({ filters: { name: "external-value" } });
    expect(wrapper.find("#filter-name").element.value).toBe("typing");

    vi.advanceTimersByTime(400);
    expect(wrapper.emitted("update:filters").at(-1)).toEqual([{ name: "typing" }]);
  });

  it("applies an external filters update for a field that isn't pending", async () => {
    const wrapper = mount(TableFilterBar, {
      props: { filters: { name: "" }, otherFields: [TEXT_FIELD] },
    });

    await wrapper.setProps({ filters: { name: "server-value" } });
    expect(wrapper.find("#filter-name").element.value).toBe("server-value");
  });

  it("emits update:filters immediately for a select field, without debouncing", async () => {
    const wrapper = mount(TableFilterBar, {
      props: { filters: { status: "" }, otherFields: [SELECT_FIELD] },
    });

    await wrapper.find("#filter-status").setValue("pending");

    expect(wrapper.emitted("update:filters")).toEqual([[{ status: "pending" }]]);
  });

  it("emits both from/to keys on a date range change", async () => {
    const range = { fromKey: "created_after", toKey: "created_before", label: "Created" };
    const wrapper = mount(TableFilterBar, {
      props: { filters: { created_after: "", created_before: "" }, dateRange: range },
    });

    await wrapper.findComponent(DateRangeFilter).vm.$emit("change", { from: "a", to: "b" });

    expect(wrapper.emitted("update:filters")).toEqual([[{ created_after: "a", created_before: "b" }]]);
  });

  it("merges the singular dateRange with the plural dateRanges list", () => {
    const wrapper = mount(TableFilterBar, {
      props: {
        filters: {},
        dateRange: { fromKey: "a_after", toKey: "a_before" },
        dateRanges: [{ fromKey: "b_after", toKey: "b_before" }],
      },
    });

    expect(wrapper.findAllComponents(DateRangeFilter)).toHaveLength(2);
  });

  it("renders nothing when there are no fields, search, or date ranges", () => {
    const wrapper = mount(TableFilterBar, { props: { filters: {} } });
    expect(wrapper.find("div").exists()).toBe(false);
  });
});
