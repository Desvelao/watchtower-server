<script setup>
import { computed, reactive, watch } from "vue";
import DateRangeFilter from "./DateRangeFilter.vue";
import { debounce } from "../../utils/debounce";

const props = defineProps({
  filters: { type: Object, default: () => ({}) },
  otherFields: { type: Array, default: () => [] },
  search: { type: Object, default: null },
  // Single-range shorthand, kept alongside `dateRanges` (plural) so every
  // existing single-range caller is unaffected - `allDateRanges` below
  // merges both into one list to actually render.
  dateRange: { type: Object, default: null },
  dateRanges: { type: Array, default: () => [] },
  debounceMs: { type: Number, default: 400 },
});

const emit = defineEmits(["update:filters"]);

// Tailwind's JIT scanner only picks up class names it finds literally in
// source, so the top row's column count can't be built by string
// interpolation - it's looked up from a fixed table of literal classes
// instead (same convention as AlertSeverityBadge's tone->class map).
const GRID_COLS = {
  0: "",
  1: "sm:grid-cols-1 lg:grid-cols-1",
  2: "sm:grid-cols-2 lg:grid-cols-2",
  3: "sm:grid-cols-3 lg:grid-cols-3",
  4: "sm:grid-cols-2 lg:grid-cols-4",
  5: "sm:grid-cols-3 lg:grid-cols-5",
  6: "sm:grid-cols-3 lg:grid-cols-6",
  7: "sm:grid-cols-3 lg:grid-cols-7",
  8: "sm:grid-cols-3 lg:grid-cols-8",
};
const otherFieldsGridClass = computed(() => GRID_COLS[props.otherFields.length] ?? GRID_COLS[8]);

const allDateRanges = computed(() =>
  props.dateRange ? [props.dateRange, ...props.dateRanges] : props.dateRanges,
);

const draftFilters = reactive({ ...props.filters });
const debouncedEmitters = new Map();
// Fields with a debounced emit still pending shouldn't be overwritten by an
// external filters change (e.g. a badge-click filter elsewhere while the
// user is mid-keystroke in another field) until their own emit resolves.
const pendingFields = new Set();

watch(
  () => props.filters,
  (next) => {
    for (const key of Object.keys(next)) {
      if (!pendingFields.has(key)) draftFilters[key] = next[key];
    }
  },
  { deep: true },
);

function getDebouncedEmit(key) {
  if (!debouncedEmitters.has(key)) {
    debouncedEmitters.set(
      key,
      debounce((patch) => {
        emit("update:filters", patch);
        pendingFields.delete(key);
      }, props.debounceMs),
    );
  }
  return debouncedEmitters.get(key);
}

function onTextInput(field) {
  pendingFields.add(field.key);
  getDebouncedEmit(field.key)({ [field.key]: draftFilters[field.key] });
}

function onImmediateChange(field) {
  emit("update:filters", { [field.key]: draftFilters[field.key] });
}

function onDateRangeChange(range, { from, to }) {
  draftFilters[range.fromKey] = from;
  draftFilters[range.toKey] = to;
  emit("update:filters", { [range.fromKey]: from, [range.toKey]: to });
}
</script>

<template>
  <div v-if="otherFields.length || search || allDateRanges.length" class="mt-4 space-y-3">
    <div
      v-if="otherFields.length"
      class="grid grid-cols-2 gap-3 rounded-lg border border-slate-200 bg-white p-4 dark:border-slate-700 dark:bg-slate-800"
      :class="otherFieldsGridClass"
    >
      <div v-for="field in otherFields" :key="field.key">
        <label
          :for="`filter-${field.key}`"
          class="block text-xs font-medium text-slate-500 dark:text-slate-400"
          :title="field.title"
        >
          {{ field.label }}
        </label>
        <select
          v-if="field.type === 'select'"
          :id="`filter-${field.key}`"
          v-model="draftFilters[field.key]"
          class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          @change="onImmediateChange(field)"
        >
          <option v-for="opt in field.options" :key="opt.value" :value="opt.value">{{ opt.label }}</option>
        </select>
        <input
          v-else
          :id="`filter-${field.key}`"
          v-model="draftFilters[field.key]"
          type="text"
          :placeholder="field.placeholder"
          class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          @input="onTextInput(field)"
        />
      </div>
    </div>

    <div
      v-if="search || allDateRanges.length"
      class="flex flex-wrap items-start gap-3 rounded-lg border border-slate-200 bg-white p-4 dark:border-slate-700 dark:bg-slate-800"
    >
      <div v-if="search" class="min-w-[180px] flex-1">
        <label for="filter-search" class="block text-xs font-medium text-slate-500 dark:text-slate-400">{{ search.label || "Search" }}</label>
        <input
          id="filter-search"
          v-model="draftFilters[search.key]"
          type="text"
          :placeholder="search.placeholder"
          class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          @input="onTextInput(search)"
        />
      </div>
      <div v-for="range in allDateRanges" :key="range.fromKey" class="w-64">
        <label :id="`filter-date-range-label-${range.fromKey}`" class="block text-xs font-medium text-slate-500 dark:text-slate-400">{{ range.label || "Date range" }}</label>
        <DateRangeFilter
          :from="draftFilters[range.fromKey]"
          :to="draftFilters[range.toKey]"
          :aria-labelledby="`filter-date-range-label-${range.fromKey}`"
          @change="(v) => onDateRangeChange(range, v)"
        />
      </div>
    </div>
  </div>
</template>
