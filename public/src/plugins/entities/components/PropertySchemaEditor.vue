<script setup>
import FieldArrayInput from '../../../components/common/FieldArrayInput.vue';
import IconDelete from '../../../components/common/icons/IconDelete.vue';
import IconPlus from '../../../components/common/icons/IconPlus.vue';

const props = defineProps({
  modelValue: { type: Array, required: true },
  label: { type: String, default: '' },
  showListColumnOption: { type: Boolean, default: false },
});

const emit = defineEmits(['update:modelValue']);

const TYPES = ['string', 'number', 'boolean', 'date', 'url', 'enum', 'map'];

function updateAt(index, patch) {
  const next = props.modelValue.map((row, i) => (i === index ? { ...row, ...patch } : row));
  emit('update:modelValue', next);
}

function updateValidationAt(index, patch) {
  const row = props.modelValue[index];
  updateAt(index, { validations: { ...(row.validations || {}), ...patch } });
}

function add() {
  emit('update:modelValue', [
    ...props.modelValue,
    {
      name: '',
      label: '',
      description: '',
      group: '',
      type: 'string',
      multiple: false,
      required: false,
      searchable: false,
      list_column: false,
      validations: {},
    },
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
        <div class="grid grid-cols-1 gap-2 sm:grid-cols-2">
          <div>
            <label class="block text-xs font-medium text-slate-600 dark:text-slate-400">Name</label>
            <input
              :value="row.name"
              type="text"
              placeholder="e.g. price"
              class="mt-0.5 w-full rounded border border-slate-300 px-2 py-1 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
              @input="updateAt(index, { name: $event.target.value })"
            />
          </div>
          <div>
            <label class="block text-xs font-medium text-slate-600 dark:text-slate-400">Label</label>
            <input
              :value="row.label"
              type="text"
              placeholder="e.g. Price"
              class="mt-0.5 w-full rounded border border-slate-300 px-2 py-1 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
              @input="updateAt(index, { label: $event.target.value })"
            />
          </div>
          <div>
            <label class="block text-xs font-medium text-slate-600 dark:text-slate-400">Type</label>
            <select
              :value="row.type"
              class="mt-0.5 w-full rounded border border-slate-300 px-2 py-1 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
              @change="updateAt(index, { type: $event.target.value, validations: {} })"
            >
              <option v-for="t in TYPES" :key="t" :value="t">{{ t }}</option>
            </select>
          </div>
          <div class="flex items-end gap-3 pb-1">
            <label class="flex items-center gap-1.5 text-xs font-medium text-slate-600 dark:text-slate-400">
              <input type="checkbox" :checked="row.multiple" @change="updateAt(index, { multiple: $event.target.checked })" />
              Multiple
            </label>
            <label class="flex items-center gap-1.5 text-xs font-medium text-slate-600 dark:text-slate-400">
              <input type="checkbox" :checked="row.required" @change="updateAt(index, { required: $event.target.checked })" />
              Required
            </label>
            <label
              v-if="['string', 'url', 'enum'].includes(row.type)"
              class="flex items-center gap-1.5 text-xs font-medium text-slate-600 dark:text-slate-400"
            >
              <input type="checkbox" :checked="row.searchable" @change="updateAt(index, { searchable: $event.target.checked })" />
              Searchable
            </label>
            <label
              v-if="showListColumnOption"
              class="flex items-center gap-1.5 text-xs font-medium text-slate-600 dark:text-slate-400"
              title="Show this field as an extra column in the Observer Configs table when this observable type is selected"
            >
              <input type="checkbox" :checked="row.list_column" @change="updateAt(index, { list_column: $event.target.checked })" />
              Show as column
            </label>
          </div>
        </div>

        <div class="mt-2 grid grid-cols-1 gap-2 sm:grid-cols-2">
          <div>
            <label class="block text-xs font-medium text-slate-600 dark:text-slate-400">Group</label>
            <input
              :value="row.group"
              type="text"
              placeholder="e.g. Page validation"
              class="mt-0.5 w-full rounded border border-slate-300 px-2 py-1 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
              @input="updateAt(index, { group: $event.target.value })"
            />
            <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">Optional. Fields sharing a group render together under one heading.</p>
          </div>
          <div>
            <label class="block text-xs font-medium text-slate-600 dark:text-slate-400">Description</label>
            <input
              :value="row.description"
              type="text"
              placeholder="Shown near this field's input"
              class="mt-0.5 w-full rounded border border-slate-300 px-2 py-1 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
              @input="updateAt(index, { description: $event.target.value })"
            />
          </div>
        </div>

        <div v-if="row.type === 'enum'" class="mt-2">
          <FieldArrayInput
            label="Options"
            :model-value="row.validations?.options || ['']"
            @update:model-value="updateValidationAt(index, { options: $event })"
          />
        </div>

        <div v-else-if="['string', 'url'].includes(row.type)" class="mt-2 grid grid-cols-3 gap-2">
          <div>
            <label class="block text-xs font-medium text-slate-600 dark:text-slate-400">Min length</label>
            <input
              type="number"
              :value="row.validations?.minLength ?? ''"
              class="mt-0.5 w-full rounded border border-slate-300 px-2 py-1 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
              @input="updateValidationAt(index, { minLength: $event.target.value === '' ? undefined : Number($event.target.value) })"
            />
          </div>
          <div>
            <label class="block text-xs font-medium text-slate-600 dark:text-slate-400">Max length</label>
            <input
              type="number"
              :value="row.validations?.maxLength ?? ''"
              class="mt-0.5 w-full rounded border border-slate-300 px-2 py-1 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
              @input="updateValidationAt(index, { maxLength: $event.target.value === '' ? undefined : Number($event.target.value) })"
            />
          </div>
          <div>
            <label class="block text-xs font-medium text-slate-600 dark:text-slate-400">Pattern</label>
            <input
              type="text"
              :value="row.validations?.pattern ?? ''"
              class="mt-0.5 w-full rounded border border-slate-300 px-2 py-1 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
              @input="updateValidationAt(index, { pattern: $event.target.value || undefined })"
            />
          </div>
        </div>

        <div v-else-if="['number', 'date'].includes(row.type)" class="mt-2 grid grid-cols-2 gap-2">
          <div>
            <label class="block text-xs font-medium text-slate-600 dark:text-slate-400">Min</label>
            <input
              :type="row.type === 'date' ? 'date' : 'number'"
              :value="row.validations?.min ?? ''"
              class="mt-0.5 w-full rounded border border-slate-300 px-2 py-1 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
              @input="updateValidationAt(index, { min: $event.target.value === '' ? undefined : (row.type === 'date' ? $event.target.value : Number($event.target.value)) })"
            />
          </div>
          <div>
            <label class="block text-xs font-medium text-slate-600 dark:text-slate-400">Max</label>
            <input
              :type="row.type === 'date' ? 'date' : 'number'"
              :value="row.validations?.max ?? ''"
              class="mt-0.5 w-full rounded border border-slate-300 px-2 py-1 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
              @input="updateValidationAt(index, { max: $event.target.value === '' ? undefined : (row.type === 'date' ? $event.target.value : Number($event.target.value)) })"
            />
          </div>
        </div>

        <div class="mt-2 flex justify-end">
          <button
            type="button"
            title="Remove property"
            aria-label="Remove property"
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
      Add property
    </button>
  </div>
</template>
