<script setup>
defineProps({
  status: { type: String, required: true },
});

const CLASSES = {
  inactive: "bg-slate-100 text-slate-600 dark:bg-slate-700 dark:text-slate-300",
  pending: "bg-yellow-100 text-yellow-800 dark:bg-yellow-900/40 dark:text-yellow-300",
  triggering: "bg-orange-100 text-orange-800 dark:bg-orange-900/40 dark:text-orange-300",
  acknowledged: "bg-green-100 text-green-800 dark:bg-green-900/40 dark:text-green-300",
  error: "bg-red-100 text-red-800 dark:bg-red-900/40 dark:text-red-300",
};
</script>

<template>
  <span
    class="inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium capitalize"
    :class="CLASSES[status] || 'bg-slate-100 text-slate-600 dark:bg-slate-700 dark:text-slate-300'"
  >
    {{ status }}
  </span>
</template>
