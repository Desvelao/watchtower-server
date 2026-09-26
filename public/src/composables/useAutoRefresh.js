import { onUnmounted, ref, watch } from "vue";

// Drives DataTable's optional auto-refresh: a user-selected interval (ms,
// 0 = off) repeatedly invokes `onTick` (DataTable's own `emit('refresh')`).
// Uses a setTimeout chain rather than setInterval so a tick that lands while
// isLoading is still true simply reschedules instead of firing again,
// preventing overlapping refreshes on a slow request.
export function useAutoRefresh(onTick, isLoading, { storageKey } = {}) {
  const intervalMs = ref(storageKey ? Number(localStorage.getItem(storageKey)) || 0 : 0);
  let timerId = null;

  function clear() {
    if (timerId) {
      clearTimeout(timerId);
      timerId = null;
    }
  }

  function scheduleNext() {
    clear();
    if (!intervalMs.value) return;
    timerId = setTimeout(() => {
      if (isLoading.value) {
        scheduleNext();
      } else {
        onTick();
      }
    }, intervalMs.value);
  }

  watch(isLoading, (loading) => {
    if (!loading) scheduleNext();
  });

  watch(intervalMs, (value) => {
    if (storageKey) localStorage.setItem(storageKey, String(value));
    scheduleNext();
  });

  onUnmounted(clear);

  return { intervalMs };
}
