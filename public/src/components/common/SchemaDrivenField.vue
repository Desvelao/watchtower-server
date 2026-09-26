<script setup>
import { computed } from 'vue';
import FieldArrayInput from './FieldArrayInput.vue';

const props = defineProps({
  definition: { type: Object, required: true },
  modelValue: { type: [String, Number, Boolean, Array], default: null },
});

const emit = defineEmits(['update:modelValue']);

const inputId = computed(() => `field-${props.definition.name}`);

const htmlType = computed(() => {
  switch (props.definition.type) {
    case 'number':
      return 'number';
    case 'date':
      return 'date';
    case 'url':
      return 'url';
    default:
      return 'text';
  }
});

const validationAttrs = computed(() => {
  const v = props.definition.validations || {};
  const attrs = {};
  if (props.definition.required) attrs.required = true;
  if (v.minLength != null) attrs.minlength = v.minLength;
  if (v.maxLength != null) attrs.maxlength = v.maxLength;
  if (v.pattern) attrs.pattern = v.pattern;
  if (v.min != null) attrs.min = v.min;
  if (v.max != null) attrs.max = v.max;
  return attrs;
});

function onScalarInput(event) {
  const raw = event.target.value;
  emit('update:modelValue', props.definition.type === 'number' ? (raw === '' ? null : Number(raw)) : raw);
}

function onBooleanInput(event) {
  emit('update:modelValue', event.target.checked);
}

function onArrayInput(next) {
  emit(
    'update:modelValue',
    props.definition.type === 'number' ? next.map((v) => (v === '' ? null : Number(v))) : next,
  );
}
</script>

<template>
  <div>
    <label
      v-if="definition.type !== 'boolean' || definition.multiple"
      :for="inputId"
      class="block text-sm font-medium text-slate-700 dark:text-slate-300"
    >
      {{ definition.label || definition.name }}<span v-if="definition.required" class="text-red-500"> *</span>
    </label>

    <FieldArrayInput
      v-if="definition.multiple"
      :model-value="(modelValue || []).map((v) => (v == null ? '' : String(v)))"
      @update:model-value="onArrayInput"
    />

    <select
      v-else-if="definition.type === 'enum'"
      :id="inputId"
      :value="modelValue ?? ''"
      :required="definition.required"
      class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
      @change="onScalarInput"
    >
      <option value="" disabled>Select…</option>
      <option v-for="opt in definition.validations?.options || []" :key="opt" :value="opt">{{ opt }}</option>
    </select>

    <div v-else-if="definition.type === 'boolean'" class="mt-1 flex items-center gap-2">
      <input :id="inputId" type="checkbox" :checked="!!modelValue" @change="onBooleanInput" />
      <label :for="inputId" class="text-sm font-medium text-slate-700 dark:text-slate-300">
        {{ definition.label || definition.name }}
      </label>
    </div>

    <input
      v-else
      :id="inputId"
      :type="htmlType"
      :value="modelValue ?? ''"
      v-bind="validationAttrs"
      class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
      @input="onScalarInput"
    />
  </div>
</template>
