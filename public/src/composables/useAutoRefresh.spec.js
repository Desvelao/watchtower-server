import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { defineComponent, h, nextTick, ref } from "vue";
import { mount } from "@vue/test-utils";
import { useAutoRefresh } from "./useAutoRefresh";

// useAutoRefresh calls onUnmounted, which only binds to a real component
// lifecycle - so tests mount it inside a tiny host component (rather than a
// bare effectScope) and drive teardown via wrapper.unmount(), matching how
// it's actually consumed from DataTable.vue's <script setup>.
function mountAutoRefresh(isLoading, options) {
  const onTick = vi.fn();
  let intervalMs;
  const TestComponent = defineComponent({
    setup() {
      ({ intervalMs } = useAutoRefresh(onTick, isLoading, options));
      return () => h("div");
    },
  });
  const wrapper = mount(TestComponent);
  return { wrapper, onTick, get intervalMs() { return intervalMs; } };
}

describe("useAutoRefresh", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    localStorage.clear();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("defaults intervalMs to 0 and never calls onTick", () => {
    const { intervalMs, onTick, wrapper } = mountAutoRefresh(ref(false));
    expect(intervalMs.value).toBe(0);
    vi.advanceTimersByTime(10 * 60 * 1000);
    expect(onTick).not.toHaveBeenCalled();
    wrapper.unmount();
  });

  it("fires onTick after the selected interval, and again after another interval", async () => {
    const isLoading = ref(false);
    const { intervalMs, onTick, wrapper } = mountAutoRefresh(isLoading);
    intervalMs.value = 1000;
    await nextTick();

    vi.advanceTimersByTime(1000);
    expect(onTick).toHaveBeenCalledTimes(1);

    // In real usage, onTick (DataTable's `emit('refresh')`) causes the
    // bound `loading` prop to cycle true -> false, which is what drives the
    // next reschedule (see useAutoRefresh's isLoading watcher) - simulate
    // that request cycle here.
    isLoading.value = true;
    await nextTick();
    isLoading.value = false;
    await nextTick();

    vi.advanceTimersByTime(1000);
    expect(onTick).toHaveBeenCalledTimes(2);
    wrapper.unmount();
  });

  it("does not call onTick while isLoading is true; fires once loading flips back to false", async () => {
    const isLoading = ref(true);
    const { intervalMs, onTick, wrapper } = mountAutoRefresh(isLoading);
    intervalMs.value = 1000;
    await nextTick();

    vi.advanceTimersByTime(5000);
    expect(onTick).not.toHaveBeenCalled();

    isLoading.value = false;
    await nextTick();
    vi.advanceTimersByTime(1000);
    expect(onTick).toHaveBeenCalledTimes(1);
    wrapper.unmount();
  });

  it("clears the pending timer on unmount so no further onTick calls happen", async () => {
    const { intervalMs, onTick, wrapper } = mountAutoRefresh(ref(false));
    intervalMs.value = 1000;
    await nextTick();

    wrapper.unmount();
    vi.advanceTimersByTime(10000);
    expect(onTick).not.toHaveBeenCalled();
  });

  it("reads the initial value from localStorage and writes updates back", async () => {
    localStorage.setItem("watchtower_auto_refresh_interval", "30000");
    const { intervalMs, wrapper } = mountAutoRefresh(
      ref(false),
      { storageKey: "watchtower_auto_refresh_interval" },
    );
    expect(intervalMs.value).toBe(30000);

    intervalMs.value = 60000;
    await nextTick();
    expect(localStorage.getItem("watchtower_auto_refresh_interval")).toBe("60000");
    wrapper.unmount();
  });
});
