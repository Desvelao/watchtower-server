<script setup>
import { computed, reactive, watch } from 'vue';
import FieldArrayInput from './FieldArrayInput.vue';
import KeyValueListInput from './KeyValueListInput.vue';

// Renders a form for an arbitrary PropertyDefinition[] schema (see
// server/lib/property_schema.lua) - grouped by each field's own `group`
// label (ungrouped fields first, no heading), with `description` shown as
// helper text under each input. `modelValue` is the plain values object
// (e.g. an observer_configs row's `mechanism_config`) - this component
// keeps its own local, per-field editing state (arrays/key-value rows can
// hold in-progress blank entries the user is still typing into) and only
// emits a cleaned-up (blanks/empty stripped) `modelValue` on change, never
// echoing its own local editing artifacts back out.
const props = defineProps({
  schema: { type: Array, default: () => [] },
  modelValue: { type: Object, default: () => ({}) },
});

const emit = defineEmits(['update:modelValue']);

const local = reactive({});
let lastEmitted = null;

function editableFor(field, raw) {
  if (field.type === 'map') {
    const entries = raw ? Object.entries(raw) : [];
    return entries.length ? entries.map(([key, value]) => ({ key, value })) : [{ key: '', value: '' }];
  }
  if (field.multiple) {
    return raw && raw.length ? [...raw] : [''];
  }
  if (field.type === 'boolean') {
    return raw; // undefined | true | false
  }
  return raw ?? '';
}

function syncFromModelValue() {
  for (const field of props.schema) {
    local[field.name] = editableFor(field, props.modelValue ? props.modelValue[field.name] : undefined);
  }
}

// Deep-equality (not reference) check: `modelValue` passed back in via
// v-model can be a different object/Proxy identity than what we emitted
// (e.g. once Vue wraps it into a parent's own reactive() object), so a
// reference check would false-negative and wipe in-progress blank rows on
// every keystroke.
watch(
  () => props.modelValue,
  (v) => {
    if (JSON.stringify(v || {}) === JSON.stringify(lastEmitted || {})) return;
    syncFromModelValue();
  },
  { immediate: true },
);
watch(() => props.schema, syncFromModelValue);

function emitUpdate() {
  const result = {};
  for (const field of props.schema) {
    const raw = local[field.name];
    if (field.type === 'map') {
      const map = {};
      for (const row of raw || []) {
        const key = (row.key || '').trim();
        if (key) map[key] = row.value ?? '';
      }
      if (Object.keys(map).length) result[field.name] = map;
    } else if (field.multiple) {
      const arr = (raw || [])
        .map((v) => (typeof v === 'string' ? v.trim() : v))
        .filter((v) => v !== '' && v !== undefined && v !== null);
      if (arr.length) result[field.name] = arr;
    } else if (field.type === 'boolean') {
      if (raw !== undefined) result[field.name] = raw;
    } else if (raw !== '' && raw !== undefined && raw !== null) {
      result[field.name] = field.type === 'number' ? Number(raw) : raw;
    }
  }
  lastEmitted = result;
  emit('update:modelValue', result);
}

function setLocal(field, value) {
  local[field.name] = value;
  emitUpdate();
}

function triStateValue(field) {
  const v = local[field.name];
  if (v === true) return 'true';
  if (v === false) return 'false';
  return '';
}

function setTriState(field, raw) {
  setLocal(field, raw === '' ? undefined : raw === 'true');
}

const sections = computed(() => {
  const ungrouped = [];
  const groups = [];
  const byGroup = {};
  for (const field of props.schema) {
    const g = field.group && field.group.trim();
    if (!g) {
      ungrouped.push(field);
      continue;
    }
    if (!byGroup[g]) {
      byGroup[g] = { key: g, fields: [] };
      groups.push(byGroup[g]);
    }
    byGroup[g].fields.push(field);
  }
  const result = [];
  if (ungrouped.length) result.push({ key: null, fields: ungrouped });
  result.push(...groups);
  return result;
});
</script>

<template>
  <div class="space-y-4">
    <p v-if="!schema.length" class="text-sm text-slate-500 dark:text-slate-400">
      No fields defined for this observable type / observer type.
    </p>

    <div v-for="section in sections" :key="section.key || '__ungrouped__'">
      <h3
        v-if="section.key"
        class="border-t border-slate-200 pt-3 text-sm font-semibold text-slate-900 dark:border-slate-700 dark:text-slate-100"
      >
        {{ section.key }}
      </h3>
      <div class="space-y-3" :class="section.key ? 'mt-2' : ''">
        <div v-for="field in section.fields" :key="field.name">
          <label class="block text-sm font-medium text-slate-700 dark:text-slate-300">
            {{ field.label || field.name }}
            <span v-if="field.required" class="text-red-600 dark:text-red-400">*</span>
          </label>

          <FieldArrayInput
            v-if="field.multiple && field.type !== 'map'"
            class="mt-1"
            :model-value="local[field.name]"
            :required="false"
            @update:model-value="setLocal(field, $event)"
          />

          <KeyValueListInput
            v-else-if="field.type === 'map'"
            class="mt-1"
            :model-value="local[field.name]"
            @update:model-value="setLocal(field, $event)"
          />

          <select
            v-else-if="field.type === 'boolean' && !field.required"
            :value="triStateValue(field)"
            class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
            @change="setTriState(field, $event.target.value)"
          >
            <option value="">Not set (default)</option>
            <option value="true">True</option>
            <option value="false">False</option>
          </select>

          <input
            v-else-if="field.type === 'boolean'"
            type="checkbox"
            class="mt-1"
            :checked="!!local[field.name]"
            @change="setLocal(field, $event.target.checked)"
          />

          <select
            v-else-if="field.type === 'enum'"
            :value="local[field.name]"
            class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
            @change="setLocal(field, $event.target.value)"
          >
            <option value="" disabled>Select...</option>
            <option v-for="opt in field.validations?.options || []" :key="opt" :value="opt">{{ opt }}</option>
          </select>

          <input
            v-else
            :type="field.type === 'number' ? 'number' : field.type === 'date' ? 'date' : 'text'"
            :value="local[field.name]"
            class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
            @input="setLocal(field, $event.target.value)"
          />

          <p v-if="field.description" class="mt-1 text-xs text-slate-500 dark:text-slate-400">{{ field.description }}</p>
        </div>
      </div>
    </div>
  </div>
</template>
