import { ref, computed, watch } from "vue";

export function useSelection(itemsRef, idKey = "id") {
  const selected = ref(new Set());

  // whenever the visible item set changes (new page, filter, refresh, or
  // after a bulk action's own refetch), drop any selection that may no
  // longer be valid/visible
  watch(itemsRef, () => {
    selected.value = new Set();
  });

  const count = computed(() => selected.value.size);
  const allSelected = computed(
    () => itemsRef.value.length > 0 && itemsRef.value.every((item) => selected.value.has(item[idKey]))
  );

  function toggle(id) {
    const next = new Set(selected.value);
    next.has(id) ? next.delete(id) : next.add(id);
    selected.value = next;
  }

  function toggleAll() {
    selected.value = allSelected.value ? new Set() : new Set(itemsRef.value.map((item) => item[idKey]));
  }

  function clear() {
    selected.value = new Set();
  }

  return { selected, count, allSelected, toggle, toggleAll, clear };
}
