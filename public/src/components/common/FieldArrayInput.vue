<script setup>
import IconDelete from './icons/IconDelete.vue';
import IconPlus from './icons/IconPlus.vue';

const props = defineProps({
  modelValue: { type: Array, required: true },
  label: { type: String, default: '' },
  placeholder: { type: String, default: '' },
  required: { type: Boolean, default: true },
});

const emit = defineEmits(['update:modelValue']);

function updateAt(index, value) {
  const next = [...props.modelValue];
  next[index] = value;
  emit('update:modelValue', next);
}

function add() {
  emit('update:modelValue', [...props.modelValue, '']);
}

function removeAt(index) {
  const next = [...props.modelValue];
  next.splice(index, 1);
  emit('update:modelValue', next);
}
</script>

<template>
  <div>
    <label v-if="label" class="block text-sm font-medium text-slate-700 dark:text-slate-300">{{ label }}</label>
    <div class="mt-1 space-y-2">
      <div v-for="(value, index) in modelValue" :key="index" class="flex items-center gap-2">
        <input
          :value="value"
          type="text"
          :required="required"
          :placeholder="placeholder"
          class="w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          @input="updateAt(index, $event.target.value)"
        />
        <button
          v-if="modelValue.length > 1"
          type="button"
          title="Remove"
          aria-label="Remove entry"
          class="shrink-0 rounded p-1.5 text-red-600 hover:bg-red-50 hover:text-red-800 dark:text-red-400 dark:hover:bg-red-900/30 dark:hover:text-red-300"
          @click="removeAt(index)"
        >
          <IconDelete class="h-4 w-4" />
        </button>
      </div>
    </div>
    <button
      type="button"
      class="mt-2 flex items-center gap-1.5 rounded border border-slate-300 px-2.5 py-1 text-xs font-medium text-slate-700 hover:bg-slate-100 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
      @click="add"
    >
      <IconPlus class="h-3.5 w-3.5" />
      Add
    </button>
  </div>
</template>
