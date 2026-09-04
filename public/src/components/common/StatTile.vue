<script setup>
import { computed } from "vue";
import { RouterLink } from "vue-router";

const props = defineProps({
  label: { type: String, required: true },
  value: { type: [Number, String], required: true },
  tone: { type: String, default: "neutral" },
  to: { type: [String, Object], default: null },
});

// Literal Tailwind class strings (not interpolated) so Tailwind's scanner
// picks them all up - matches the pattern already used in
// AlertPriorityBadge/AlertStatusBadge.
const TONE_CLASSES = {
  neutral: {
    border: "border-slate-200 dark:border-slate-700",
    value: "text-slate-900 dark:text-slate-100",
  },
  slate: {
    border: "border-slate-200 border-l-4 border-l-slate-400 dark:border-slate-700 dark:border-l-slate-500",
    value: "text-slate-700 dark:text-slate-300",
  },
  blue: {
    border: "border-slate-200 border-l-4 border-l-blue-500 dark:border-slate-700",
    value: "text-blue-700 dark:text-blue-400",
  },
  orange: {
    border: "border-slate-200 border-l-4 border-l-orange-500 dark:border-slate-700",
    value: "text-orange-700 dark:text-orange-400",
  },
  red: {
    border: "border-slate-200 border-l-4 border-l-red-500 dark:border-slate-700",
    value: "text-red-700 dark:text-red-400",
  },
};

const classes = TONE_CLASSES[props.tone] || TONE_CLASSES.neutral;

const tag = computed(() => (props.to ? RouterLink : "div"));
const linkProps = computed(() => (props.to ? { to: props.to } : {}));
</script>

<template>
  <component
    :is="tag"
    v-bind="linkProps"
    class="block rounded-lg border bg-white p-4 transition-colors dark:bg-slate-800"
    :class="[
      classes.border,
      to ? 'hover:border-slate-300 hover:shadow-sm cursor-pointer dark:hover:border-slate-600' : '',
    ]"
  >
    <p class="text-sm text-slate-500 dark:text-slate-400">{{ label }}</p>
    <p class="mt-1 text-2xl font-semibold" :class="classes.value">{{ value }}</p>
  </component>
</template>
