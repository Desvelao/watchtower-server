<script setup>
import FieldArrayInput from '../../../components/common/FieldArrayInput.vue';
import IconDelete from '../../../components/common/icons/IconDelete.vue';
import IconPlus from '../../../components/common/icons/IconPlus.vue';

const props = defineProps({
  modelValue: { type: Array, required: true },
  label: { type: String, default: '' },
});

const emit = defineEmits(['update:modelValue']);

const MODES = ['selector', 'compute'];

function updateAt(index, patch) {
  const next = props.modelValue.map((row, i) => (i === index ? { ...row, ...patch } : row));
  emit('update:modelValue', next);
}

function add() {
  emit('update:modelValue', [
    ...props.modelValue,
    { name: '', locked: false, mode: 'selector', selector: [''], compute: '', transform: '', validate: '', temporal: false },
  ]);
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

    <div class="mt-1 space-y-3">
      <div
        v-for="(row, index) in modelValue"
        :key="index"
        class="rounded border border-slate-200 p-3 dark:border-slate-700"
      >
        <div class="flex flex-wrap items-end gap-2">
          <div class="flex-1">
            <label class="block text-xs font-medium text-slate-600 dark:text-slate-400">Name</label>
            <p v-if="row.locked" class="mt-0.5 py-1 text-sm font-medium capitalize text-slate-900 dark:text-slate-100">
              {{ row.name }}
              <span v-if="row.required" class="ml-1 text-xs font-normal normal-case text-slate-500 dark:text-slate-400">(required)</span>
            </p>
            <input
              v-else
              :value="row.name"
              type="text"
              placeholder="e.g. original_price"
              class="mt-0.5 w-full rounded border border-slate-300 px-2 py-1 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
              @input="updateAt(index, { name: $event.target.value })"
            />
          </div>
          <div>
            <label class="block text-xs font-medium text-slate-600 dark:text-slate-400">Mode</label>
            <select
              :value="row.mode"
              class="mt-0.5 rounded border border-slate-300 px-2 py-1 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
              @change="updateAt(index, { mode: $event.target.value })"
            >
              <option v-for="m in MODES" :key="m" :value="m">{{ m }}</option>
            </select>
          </div>
          <label
            v-if="!row.locked"
            class="flex items-center gap-1.5 pb-1.5 text-xs font-medium text-slate-600 dark:text-slate-400"
            title="Extract/compute the value but exclude it from the final observation result"
          >
            <input type="checkbox" :checked="row.temporal" @change="updateAt(index, { temporal: $event.target.checked })" />
            Temporal
          </label>
        </div>

        <div v-if="row.mode === 'selector'" class="mt-2">
          <FieldArrayInput
            label="Selector"
            :model-value="row.selector?.length ? row.selector : ['']"
            @update:model-value="updateAt(index, { selector: $event })"
          />
        </div>
        <div v-else class="mt-2">
          <label class="block text-xs font-medium text-slate-600 dark:text-slate-400">Compute expression</label>
          <input
            :value="row.compute"
            type="text"
            placeholder="e.g. (original_price - price) / original_price * 100"
            class="mt-0.5 w-full rounded border border-slate-300 px-2 py-1 font-mono text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
            @input="updateAt(index, { compute: $event.target.value })"
          />
          <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
            Arithmetic expression (+ - * / and parens) over other fields' values.
          </p>
        </div>

        <div class="mt-2 grid grid-cols-1 gap-2 sm:grid-cols-2">
          <div>
            <label class="block text-xs font-medium text-slate-600 dark:text-slate-400">Transform</label>
            <input
              :value="row.transform"
              type="text"
              class="mt-0.5 w-full rounded border border-slate-300 px-2 py-1 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
              @input="updateAt(index, { transform: $event.target.value })"
            />
          </div>
          <div>
            <label class="block text-xs font-medium text-slate-600 dark:text-slate-400">Validate</label>
            <input
              :value="row.validate"
              type="text"
              class="mt-0.5 w-full rounded border border-slate-300 px-2 py-1 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
              @input="updateAt(index, { validate: $event.target.value })"
            />
          </div>
        </div>

        <div v-if="!row.locked" class="mt-2 flex justify-end">
          <button
            type="button"
            title="Remove field"
            aria-label="Remove field"
            class="flex items-center gap-1 rounded p-1.5 text-xs font-medium text-red-600 hover:bg-red-50 hover:text-red-800 dark:text-red-400 dark:hover:bg-red-900/30 dark:hover:text-red-300"
            @click="removeAt(index)"
          >
            <IconDelete class="h-3.5 w-3.5" />
            Remove
          </button>
        </div>
      </div>
    </div>

    <button
      type="button"
      class="mt-2 flex items-center gap-1.5 rounded border border-slate-300 px-2.5 py-1 text-xs font-medium text-slate-700 hover:bg-slate-100 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
      @click="add"
    >
      <IconPlus class="h-3.5 w-3.5" />
      Add field
    </button>
  </div>
</template>
