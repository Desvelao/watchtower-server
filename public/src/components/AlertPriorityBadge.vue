<script setup>
import { PRIORITY_TONES } from "../utils/severity";

defineProps({
  priority: { type: String, required: true },
});

// Keyed by tone (see utils/severity.js) rather than priority directly, so
// this palette stays the single place the tone -> Tailwind classes mapping
// is defined.
const TONE_CLASSES = {
  slate: "bg-slate-100 text-slate-600 dark:bg-slate-700 dark:text-slate-300",
  blue: "bg-blue-100 text-blue-800 dark:bg-blue-900/40 dark:text-blue-300",
  orange: "bg-orange-100 text-orange-800 dark:bg-orange-900/40 dark:text-orange-300",
  red: "bg-red-100 text-red-800 dark:bg-red-900/40 dark:text-red-300",
};

const CLASSES = Object.fromEntries(
  Object.entries(PRIORITY_TONES).map(([priority, tone]) => [priority, TONE_CLASSES[tone]])
);
</script>

<template>
  <span
    class="inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium capitalize"
    :class="CLASSES[priority] || 'bg-slate-100 text-slate-600 dark:bg-slate-700 dark:text-slate-300'"
  >
    {{ priority }}
  </span>
</template>
