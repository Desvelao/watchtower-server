<script setup>
defineProps({
  open: { type: Boolean, default: false },
  title: { type: String, default: '' },
  maxWidthClass: { type: String, default: 'max-w-lg' },
});

const emit = defineEmits(['close']);
</script>

<template>
  <div
    v-if="open"
    class="fixed inset-0 z-50 flex justify-end bg-slate-900/40"
    @click.self="emit('close')"
  >
    <div class="h-full w-full overflow-y-auto bg-white p-5 shadow-xl dark:bg-slate-800" :class="maxWidthClass">
      <div class="flex items-center justify-between">
        <h2 class="text-base font-semibold text-slate-900 dark:text-slate-100">
          <slot name="title">{{ title }}</slot>
        </h2>
        <button
          type="button"
          title="Close"
          aria-label="Close"
          class="rounded p-1.5 text-slate-500 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="emit('close')"
        >
          ✕
        </button>
      </div>

      <slot />
    </div>
  </div>
</template>
