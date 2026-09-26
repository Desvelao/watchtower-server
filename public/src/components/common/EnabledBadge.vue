<script setup>
defineProps({
  enabled: { type: Boolean, default: false },
});
</script>

<template>
  <span
    class="inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium"
    :class="
      enabled
        ? 'bg-green-100 text-green-800 dark:bg-green-900/40 dark:text-green-300'
        : 'bg-slate-100 text-slate-600 dark:bg-slate-700 dark:text-slate-300'
    "
  >
    {{ enabled ? 'Enabled' : 'Disabled' }}
  </span>
</template>
