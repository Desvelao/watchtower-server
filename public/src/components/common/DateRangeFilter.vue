<script setup>
import { computed, onMounted, onUnmounted, ref, watch } from "vue";
import {
  DATE_RANGE_PRESETS,
  relativeDateKeyword,
  relativeDateKeywordLabel,
  relativeDateKeywordToLocalDateTime,
} from "../../utils/date";

const props = defineProps({
  from: { type: String, default: "" },
  to: { type: String, default: "" },
  presets: { type: Array, default: () => DATE_RANGE_PRESETS },
});

// A single combined event, not update:from/update:to - a preset click or
// Apply changes both values together as one user action, and firing two
// separate events would trigger two redundant fetches in the parent (see
// PaginationControls.vue for the two-independent-events shape this
// deliberately does NOT follow, since from/to aren't independent axes).
const emit = defineEmits(["change"]);

// `aria-labelledby` (and any other attrs a caller passes, e.g.
// TableFilterBar.vue's date-range label association) belongs on the
// trigger button, not this component's root wrapper div - bind it there
// explicitly instead of relying on Vue's default attrs fallthrough.
defineOptions({ inheritAttrs: false });

const open = ref(false);
const menuRef = ref(null);
const draftFrom = ref(props.from);
const draftTo = ref(props.to);
const relativeAmount = ref("");
const relativeUnit = ref("m");

function onDocumentClick(event) {
  if (open.value && menuRef.value && !menuRef.value.contains(event.target)) {
    open.value = false;
  }
}
function onKeydown(event) {
  if (event.key === "Escape" && open.value) {
    open.value = false;
  }
}
onMounted(() => {
  document.addEventListener("mousedown", onDocumentClick);
  document.addEventListener("keydown", onKeydown);
});
onUnmounted(() => {
  document.removeEventListener("mousedown", onDocumentClick);
  document.removeEventListener("keydown", onKeydown);
});

// datetime-local can't display a relative keyword like "now-1h" - resolve
// it to an approximate absolute value first so the draft inputs start from
// something sensible instead of blank/invalid. Purely a starting point for
// editing; the actual filter re-resolves server-side regardless.
function toDraftValue(value) {
  return value.startsWith("now") ? relativeDateKeywordToLocalDateTime(value) : value;
}

function toggleOpen() {
  if (!open.value) {
    draftFrom.value = toDraftValue(props.from);
    draftTo.value = toDraftValue(props.to);
  }
  open.value = !open.value;
}

// Presets are literal relative keywords now (see stores/*.js, main.lua's
// resolve_relative_date) - "active" is an exact string match, not a
// drifting-timestamp comparison. Computed from props rather than tracked
// as separate state, so the label stays correct even when from/to arrive
// from a deep-linked URL, not just a click in this popover.
const activePreset = computed(() => {
  if (props.to || !props.from) return null;
  return props.presets.find((preset) => props.from === relativeDateKeyword(preset.hours)) || null;
});

function formatLocal(value) {
  return value ? value.replace("T", " ") : "";
}

const triggerLabel = computed(() => {
  if (activePreset.value) return activePreset.value.label;
  // A relative keyword that doesn't match any configured preset (e.g. a
  // hand-edited deep link) still gets a human label instead of raw
  // "now-3h" text.
  const fromKeywordLabel = props.from && relativeDateKeywordLabel(props.from);
  if (fromKeywordLabel && !props.to) return fromKeywordLabel;
  if (!props.from && !props.to) return "All time";
  if (props.from && props.to) return `${formatLocal(props.from)} → ${formatLocal(props.to)}`;
  if (props.from) return `From ${formatLocal(props.from)}`;
  return `Until ${formatLocal(props.to)}`;
});

function selectPreset(preset) {
  emit("change", { from: relativeDateKeyword(preset.hours), to: "" });
  open.value = false;
}

function applyCustomRange() {
  emit("change", { from: draftFrom.value, to: draftTo.value });
  open.value = false;
}

// An arbitrary relative window (e.g. "last 36 minutes") that isn't one of
// the fixed preset buttons - same server-resolved keyword mechanism, just
// with a user-chosen amount/unit instead of a preset's fixed hours.
function applyRelative() {
  const amount = Number(relativeAmount.value);
  if (!amount || amount <= 0) return;
  emit("change", { from: relativeDateKeyword(amount, relativeUnit.value), to: "" });
  relativeAmount.value = "";
  open.value = false;
}

// Keep the draft in sync if the parent's value changes while closed (e.g.
// another control resets filters) so reopening starts from the real value.
watch(
  () => [props.from, props.to],
  ([from, to]) => {
    if (!open.value) {
      draftFrom.value = toDraftValue(from);
      draftTo.value = toDraftValue(to);
    }
  },
);
</script>

<template>
  <div ref="menuRef" class="relative">
    <button
      type="button"
      v-bind="$attrs"
      aria-haspopup="dialog"
      :aria-expanded="open"
      class="mt-1 flex w-full items-center justify-between gap-1 rounded border border-slate-300 px-2 py-1.5 text-left text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
      @click="toggleOpen"
    >
      <span class="truncate">{{ triggerLabel }}</span>
      <span class="text-slate-400 dark:text-slate-500">▾</span>
    </button>

    <div
      v-if="open"
      role="dialog"
      aria-modal="true"
      class="absolute left-0 z-50 mt-1 w-64 rounded-lg border border-slate-200 bg-white p-3 shadow-lg dark:border-slate-700 dark:bg-slate-800"
    >
      <div class="flex flex-col gap-0.5">
        <button
          v-for="preset in presets"
          :key="preset.key"
          type="button"
          class="rounded px-2 py-1 text-left text-sm hover:bg-slate-100 dark:hover:bg-slate-700"
          :class="
            activePreset?.key === preset.key
              ? 'font-medium text-slate-900 dark:text-slate-100'
              : 'text-slate-600 dark:text-slate-300'
          "
          @click="selectPreset(preset)"
        >
          {{ preset.label }}
        </button>
      </div>

      <div class="mt-2 flex items-end gap-1 border-t border-slate-200 pt-2 dark:border-slate-700">
        <div class="flex-1">
          <label class="block text-xs font-medium text-slate-500 dark:text-slate-400">Last</label>
          <input
            v-model="relativeAmount"
            type="number"
            min="1"
            placeholder="e.g. 36"
            class="mt-1 w-full rounded border border-slate-300 px-2 py-1 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
            @keydown.enter.prevent="applyRelative"
          />
        </div>
        <select
          v-model="relativeUnit"
          class="mt-1 rounded border border-slate-300 px-2 py-1 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
        >
          <option value="m">Minutes</option>
          <option value="h">Hours</option>
          <option value="d">Days</option>
        </select>
        <button
          type="button"
          class="mt-1 rounded bg-slate-900 px-2 py-1 text-sm font-medium text-white hover:bg-slate-800 dark:bg-slate-700 dark:hover:bg-slate-600"
          @click="applyRelative"
        >
          Apply
        </button>
      </div>

      <div class="mt-2 border-t border-slate-200 pt-2 dark:border-slate-700">
        <label class="block text-xs font-medium text-slate-500 dark:text-slate-400">From</label>
        <input
          v-model="draftFrom"
          type="datetime-local"
          class="mt-1 w-full rounded border border-slate-300 px-2 py-1 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
        />
        <label class="mt-2 block text-xs font-medium text-slate-500 dark:text-slate-400">To</label>
        <input
          v-model="draftTo"
          type="datetime-local"
          class="mt-1 w-full rounded border border-slate-300 px-2 py-1 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
        />
        <button
          type="button"
          class="mt-2 w-full rounded bg-slate-900 px-2 py-1.5 text-sm font-medium text-white hover:bg-slate-800 dark:bg-slate-700 dark:hover:bg-slate-600"
          @click="applyCustomRange"
        >
          Apply
        </button>
      </div>
    </div>
  </div>
</template>
