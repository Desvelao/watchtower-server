<script setup>
import { computed } from "vue";

const props = defineProps({
  from: { type: Number, required: true },
  size: { type: Number, required: true },
  totalItems: { type: Number, required: true },
});

const emit = defineEmits(["update:from", "update:size"]);

const page = computed(() => Math.floor(props.from / props.size) + 1);
const totalPages = computed(() => Math.max(1, Math.ceil(props.totalItems / props.size)));

function prev() {
  emit("update:from", Math.max(0, props.from - props.size));
}

function next() {
  if (props.from + props.size < props.totalItems) {
    emit("update:from", props.from + props.size);
  }
}
</script>

<template>
  <div class="flex items-center justify-between gap-4 text-sm text-slate-600 dark:text-slate-400">
    <span>Page {{ page }} of {{ totalPages }} ({{ totalItems }} total)</span>
    <div class="flex items-center gap-2">
      <select
        class="rounded border border-slate-300 px-2 py-1 dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
        :value="size"
        @change="emit('update:size', Number($event.target.value))"
      >
        <option :value="10">10 / page</option>
        <option :value="20">20 / page</option>
        <option :value="50">50 / page</option>
      </select>
      <button
        type="button"
        class="rounded border border-slate-300 px-2 py-1 disabled:opacity-40 dark:border-slate-600 dark:hover:bg-slate-700"
        :disabled="from === 0"
        @click="prev"
      >
        Prev
      </button>
      <button
        type="button"
        class="rounded border border-slate-300 px-2 py-1 disabled:opacity-40 dark:border-slate-600 dark:hover:bg-slate-700"
        :disabled="from + size >= totalItems"
        @click="next"
      >
        Next
      </button>
    </div>
  </div>
</template>
