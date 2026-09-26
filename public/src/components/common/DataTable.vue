<script setup>
import { computed, ref, useSlots, watchEffect } from "vue";
import { useAutoRefresh } from "../../composables/useAutoRefresh";
import { useSelection } from "../../composables/useSelection";
import PaginationControls from "./PaginationControls.vue";
import TableFilterBar from "./TableFilterBar.vue";
import IconRefresh from "./icons/IconRefresh.vue";

const REFRESH_INTERVAL_OPTIONS = [
  { value: 0, label: "Off" },
  { value: 10_000, label: "10s" },
  { value: 30_000, label: "30s" },
  { value: 60_000, label: "1m" },
  { value: 300_000, label: "5m" },
];

const props = defineProps({
  title: { type: String, default: "" },
  columns: { type: Array, required: true },
  items: { type: Array, required: true },
  idKey: { type: String, default: "id" },
  loading: { type: Boolean, default: false },
  error: { type: String, default: null },
  emptyText: { type: String, default: "No results found." },
  sort: { type: String, default: null },
  otherFields: { type: Array, default: () => [] },
  search: { type: Object, default: null },
  dateRange: { type: Object, default: null },
  dateRanges: { type: Array, default: () => [] },
  filters: { type: Object, default: () => ({}) },
  selectable: { type: Boolean, default: false },
  pagination: { type: Object, default: null },
  totalItems: { type: Number, default: 0 },
  expandedKeys: { type: Set, default: () => new Set() },
});

const emit = defineEmits(["refresh", "update:filters", "update:sort", "update:from", "update:size"]);

const slots = useSlots();
const hasRowActions = computed(() => !!slots["row-actions"]);
const hasRowDetail = computed(() => !!slots["row-detail"]);

const colCount = computed(
  () => props.columns.length + (props.selectable ? 1 : 0) + (hasRowActions.value ? 1 : 0),
);

/* Selection / bulk actions */

const {
  selected: selectedIds,
  count: selectedCount,
  allSelected,
  toggle: toggleSelect,
  toggleAll: toggleSelectAll,
  clear: clearSelection,
} = useSelection(
  computed(() => props.items),
  props.idKey,
);

const selectAllCheckbox = ref(null);
watchEffect(() => {
  if (selectAllCheckbox.value) {
    selectAllCheckbox.value.indeterminate = selectedCount.value > 0 && !allSelected.value;
  }
});

/* Sorting */

const activeSort = computed(() => {
  if (!props.sort) return { field: null, dir: null };
  const [field, dir] = props.sort.split(":");
  return { field, dir };
});

function sortFieldOf(column) {
  return column.sortField || column.key;
}

function sortIndicator(column) {
  if (!column.sortable || activeSort.value.field !== sortFieldOf(column)) return "";
  return activeSort.value.dir === "asc" ? "▲" : "▼";
}

function toggleSort(column) {
  if (!column.sortable) return;
  const field = sortFieldOf(column);
  const isActive = activeSort.value.field === field;
  const nextDir = isActive && activeSort.value.dir === "asc" ? "desc" : "asc";
  emit("update:sort", `${field}:${nextDir}`);
}

/* Click-to-filter */

// A column is filterable when its (own or overridden) key matches an
// available filter field - single-value cells then get auto-wrapped in a
// clickable button by the template below. Array-valued cells (tags,
// capabilities, ...) aren't auto-wrapped since there's no single value to
// filter by; views handle those themselves via the `filterBy` scope prop
// passed to every cell slot.
const otherFieldKeys = computed(() => new Set(props.otherFields.map((f) => f.key)));

function filterKeyFor(column) {
  return column.filterKey ?? column.key;
}

function isFilterable(column, item) {
  return otherFieldKeys.value.has(filterKeyFor(column)) && !Array.isArray(item[column.key]);
}

function filterBy(key, value) {
  if (!key) return;
  emit("update:filters", { [key]: value == null ? "" : String(value) });
}

/* Auto-refresh */

const { intervalMs } = useAutoRefresh(() => emit("refresh"), computed(() => props.loading), {
  storageKey: "watchtower_auto_refresh_interval",
});
</script>

<template>
  <div>
    <div class="flex items-center justify-between">
      <slot name="title">
        <h1 class="text-xl font-semibold text-slate-900 dark:text-slate-100">{{ title }}</h1>
      </slot>
      <div class="flex items-center gap-2">
        <select
          v-model.number="intervalMs"
          aria-label="Auto-refresh interval"
          class="rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
        >
          <option v-for="opt in REFRESH_INTERVAL_OPTIONS" :key="opt.value" :value="opt.value">{{ opt.label }}</option>
        </select>
        <button
          type="button"
          :disabled="loading"
          class="flex items-center gap-1.5 rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-100 disabled:opacity-50 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
          @click="emit('refresh')"
        >
          <IconRefresh class="h-4 w-4" />
          {{ loading ? "Refreshing..." : "Refresh" }}
        </button>
        <slot name="header-actions" />
      </div>
    </div>

    <slot name="description" />

    <TableFilterBar
      :filters="filters"
      :other-fields="otherFields"
      :search="search"
      :date-range="dateRange"
      :date-ranges="dateRanges"
      @update:filters="emit('update:filters', $event)"
    />

    <p v-if="error" class="mt-4 text-sm text-red-600 dark:text-red-400">{{ error }}</p>
    <slot name="messages" />

    <div
      v-if="selectable && selectedCount > 0"
      class="mt-4 flex items-center justify-between rounded-lg border border-slate-300 bg-slate-50 px-4 py-2 dark:border-slate-600 dark:bg-slate-800"
    >
      <span class="text-sm font-medium text-slate-700 dark:text-slate-300">{{ selectedCount }} selected</span>
      <div class="flex items-center gap-2">
        <slot name="bulk-actions" :selected-ids="selectedIds" :selected-count="selectedCount" :clear="clearSelection" />
        <button
          type="button"
          class="rounded px-2 py-1 text-sm font-medium text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-700"
          @click="clearSelection"
        >
          Clear
        </button>
      </div>
    </div>

    <div class="mt-4 overflow-x-auto rounded-lg border border-slate-200 bg-white dark:border-slate-700 dark:bg-slate-800">
      <table class="min-w-full divide-y divide-slate-200 text-sm dark:divide-slate-700">
        <thead class="bg-slate-50 text-left text-xs font-medium uppercase tracking-wide text-slate-500 dark:bg-slate-900 dark:text-slate-400">
          <tr>
            <th v-if="selectable" class="w-8 px-3 py-2">
              <input
                ref="selectAllCheckbox"
                type="checkbox"
                aria-label="Select all rows"
                :checked="allSelected"
                @change="toggleSelectAll"
              />
            </th>
            <th
              v-for="column in columns"
              :key="column.key"
              class="px-3 py-2"
              :class="[column.headerClass, column.sortable ? 'cursor-pointer select-none hover:bg-slate-100 dark:hover:bg-slate-700' : '']"
              @click="toggleSort(column)"
            >
              {{ column.label }}
              <span v-if="column.sortable" class="text-slate-400 dark:text-slate-500">{{ sortIndicator(column) }}</span>
            </th>
            <th v-if="hasRowActions" class="px-3 py-2 text-right">Actions</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-slate-100 dark:divide-slate-700">
          <tr v-if="loading">
            <td :colspan="colCount" class="px-3 py-4 text-center text-slate-500 dark:text-slate-400">Loading...</td>
          </tr>
          <tr v-else-if="items.length === 0">
            <td :colspan="colCount" class="px-3 py-4 text-center text-slate-500 dark:text-slate-400">{{ emptyText }}</td>
          </tr>
          <template v-for="item in items" v-else :key="item[idKey]">
            <tr>
              <td v-if="selectable" class="px-3 py-2">
                <input
                  type="checkbox"
                  :aria-label="`Select row ${item[idKey]}`"
                  :checked="selectedIds.has(item[idKey])"
                  @change="toggleSelect(item[idKey])"
                />
              </td>
              <td v-for="column in columns" :key="column.key" class="px-3 py-2" :class="column.class">
                <button
                  v-if="isFilterable(column, item)"
                  type="button"
                  :title="`Filter by this ${column.label.toLowerCase()}`"
                  class="cursor-pointer hover:opacity-75"
                  @click="filterBy(filterKeyFor(column), item[column.key])"
                >
                  <slot :name="`cell-${column.key}`" :item="item" :value="item[column.key]" :filter-by="filterBy">
                    {{ item[column.key] ?? "-" }}
                  </slot>
                </button>
                <slot v-else :name="`cell-${column.key}`" :item="item" :value="item[column.key]" :filter-by="filterBy">
                  {{ item[column.key] ?? "-" }}
                </slot>
              </td>
              <td v-if="hasRowActions" class="px-3 py-2">
                <div class="flex justify-end gap-1">
                  <slot name="row-actions" :item="item" />
                </div>
              </td>
            </tr>
            <tr v-if="hasRowDetail && expandedKeys.has(item[idKey])">
              <td :colspan="colCount" class="bg-slate-50 px-6 py-3 dark:bg-slate-900">
                <slot name="row-detail" :item="item" />
              </td>
            </tr>
          </template>
        </tbody>
      </table>
    </div>

    <div v-if="pagination" class="mt-4">
      <PaginationControls
        :from="pagination.from"
        :size="pagination.size"
        :total-items="totalItems"
        @update:from="emit('update:from', $event)"
        @update:size="emit('update:size', $event)"
      />
    </div>
  </div>
</template>
