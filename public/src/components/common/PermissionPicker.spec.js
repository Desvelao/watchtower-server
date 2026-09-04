import { describe, it, expect } from "vitest";
import { mount } from "@vue/test-utils";
import PermissionPicker from "./PermissionPicker.vue";

const PERMISSIONS = ["alerts:read", "alerts:write", "api_key:read", "events:read"];

function mountPicker(modelValue = []) {
  return mount(PermissionPicker, {
    props: { modelValue, availablePermissions: PERMISSIONS },
  });
}

// Each top-level category block renders as a `div.rounded.border` containing
// one category-level checkbox (first checkbox in the block) followed by the
// per-permission checkboxes - scope queries per block instead of relying on
// a flat/global checkbox index, since category and permission checkboxes are
// interleaved in DOM order (one category block at a time), not grouped.
function categoryBlocks(wrapper) {
  return wrapper.findAll("div.rounded.border");
}

describe("PermissionPicker", () => {
  it("groups permissions by category and formats labels", () => {
    const wrapper = mountPicker();
    const blocks = categoryBlocks(wrapper);
    expect(blocks).toHaveLength(3); // alerts, api_key, events
    const labels = blocks.map((b) => b.find("label").text());
    expect(labels).toEqual(["Alerts", "API Key", "Events"]);
  });

  it("renders one checkbox per permission, checked according to modelValue", () => {
    const wrapper = mountPicker(["alerts:read"]);
    const [alertsBlock] = categoryBlocks(wrapper);
    const permCheckboxes = alertsBlock.findAll("input[type=checkbox]").slice(1);
    expect(permCheckboxes).toHaveLength(2); // alerts:read, alerts:write
    expect(permCheckboxes[0].element.checked).toBe(true);
    expect(permCheckboxes[1].element.checked).toBe(false);
  });

  it("marks a category checkbox fully checked when every permission in it is selected", () => {
    const wrapper = mountPicker(["alerts:read", "alerts:write"]);
    const [alertsBlock] = categoryBlocks(wrapper);
    const categoryCheckbox = alertsBlock.find("input[type=checkbox]");
    expect(categoryCheckbox.element.checked).toBe(true);
    expect(categoryCheckbox.element.indeterminate).toBe(false);
  });

  it("marks a category checkbox indeterminate when only some permissions are selected", () => {
    const wrapper = mountPicker(["alerts:read"]);
    const [alertsBlock] = categoryBlocks(wrapper);
    const categoryCheckbox = alertsBlock.find("input[type=checkbox]");
    expect(categoryCheckbox.element.checked).toBe(false);
    expect(categoryCheckbox.element.indeterminate).toBe(true);
  });

  it("disables the category checkbox when the category has fewer than 2 permissions", () => {
    const wrapper = mountPicker();
    const [alertsBlock, apiKeyBlock, eventsBlock] = categoryBlocks(wrapper);
    expect(alertsBlock.find("input[type=checkbox]").element.disabled).toBe(false); // 2 perms
    expect(apiKeyBlock.find("input[type=checkbox]").element.disabled).toBe(true); // 1 perm
    expect(eventsBlock.find("input[type=checkbox]").element.disabled).toBe(true); // 1 perm
  });

  it("toggleCategory(true) adds every permission in the category, deduped, and emits update:modelValue", async () => {
    const wrapper = mountPicker(["alerts:read"]);
    const [alertsBlock] = categoryBlocks(wrapper);
    await alertsBlock.find("input[type=checkbox]").setValue(true);

    const emitted = wrapper.emitted("update:modelValue");
    expect(emitted).toBeTruthy();
    expect(emitted[emitted.length - 1][0].sort()).toEqual(["alerts:read", "alerts:write"]);
  });

  it("toggleCategory(false) removes every permission in the category and emits update:modelValue", async () => {
    const wrapper = mountPicker(["alerts:read", "alerts:write", "events:read"]);
    const [alertsBlock] = categoryBlocks(wrapper);
    await alertsBlock.find("input[type=checkbox]").setValue(false);

    const emitted = wrapper.emitted("update:modelValue");
    expect(emitted[emitted.length - 1][0]).toEqual(["events:read"]);
  });

  it("togglePermission toggles a single permission and emits update:modelValue", async () => {
    const wrapper = mountPicker(["alerts:read"]);
    const [alertsBlock] = categoryBlocks(wrapper);
    const permCheckboxes = alertsBlock.findAll("input[type=checkbox]").slice(1);
    await permCheckboxes[1].setValue(true); // alerts:write

    const emitted = wrapper.emitted("update:modelValue");
    expect(emitted[emitted.length - 1][0].sort()).toEqual(["alerts:read", "alerts:write"]);
  });

  it("togglePermission(false) removes a permission and emits update:modelValue", async () => {
    const wrapper = mountPicker(["alerts:read", "alerts:write"]);
    const [alertsBlock] = categoryBlocks(wrapper);
    const permCheckboxes = alertsBlock.findAll("input[type=checkbox]").slice(1);
    await permCheckboxes[0].setValue(false); // alerts:read off

    const emitted = wrapper.emitted("update:modelValue");
    expect(emitted[emitted.length - 1][0]).toEqual(["alerts:write"]);
  });
});
