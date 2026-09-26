<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useObserverConfigsStore } from '../../../stores/observerConfigs';
import { useObservableTypesStore } from '../../../stores/observableTypes';
import { getObserverConfig, testObserverConfig, testUnregisteredObserverConfig } from '../../../services/api/observerConfigs';
import { HTTPError } from '../../../services/api/http';
import IconFlask from '../../../components/common/icons/IconFlask.vue';
import ObserverFieldEditor from '../components/ObserverFieldEditor.vue';
import SchemaFieldsForm from '../../../components/common/SchemaFieldsForm.vue';
import SchemaDrivenForm from '../../../components/common/SchemaDrivenForm.vue';

const props = defineProps({
  id: { type: String, default: null },
});

const route = useRoute();
const router = useRouter();
const store = useObserverConfigsStore();
const observableTypesStore = useObservableTypesStore();

const configId = computed(() => props.id || route.params.id || null);
const isEdit = computed(() => !!configId.value);

function emptyFieldRow(name, locked, required) {
  return { name, locked, required, mode: 'selector', selector: [''], compute: '', transform: '', validate: '', temporal: false };
}

function fieldToRow(name, def, locked, required) {
  const mode = def?.compute ? 'compute' : 'selector';
  return {
    name,
    locked,
    required,
    mode,
    selector: mode === 'selector' && def?.selector?.length ? [...def.selector] : [''],
    compute: def?.compute || '',
    transform: def?.transform || '',
    validate: def?.validate || '',
    temporal: def?.temporal === true,
  };
}

function schemaFieldRows(observableType) {
  const schema = observableType?.observer_config_schema || [];
  return schema.map((prop) => emptyFieldRow(prop.name, true, !!prop.required));
}

const form = reactive({
  name: '',
  observable_type_id: '',
  enabled: true,
  fieldRows: [],
  mechanismConfig: {},
});

const loading = ref(isEdit.value);
const saving = ref(false);
const error = ref('');

const testProperties = ref({});
const testing = ref(false);
const testError = ref('');
const testResult = ref(null);
const hasTested = ref(false);

const selectedObservableType = computed(() =>
  observableTypesStore.items.find((t) => String(t.id) === String(form.observable_type_id)),
);

function applyItem(item, observableType) {
  form.name = item.name;
  form.observable_type_id = String(item.observable_type_id);
  form.enabled = item.enabled !== false;
  form.mechanismConfig = item.mechanism_config || {};

  const schema = observableType?.observer_config_schema || [];
  const schemaNames = new Set(schema.map((p) => p.name));
  const fields = item.fields || {};
  const rows = schema.map((prop) => fieldToRow(prop.name, fields[prop.name], true, !!prop.required));
  for (const name of Object.keys(fields)) {
    if (!schemaNames.has(name)) {
      rows.push(fieldToRow(name, fields[name], false, false));
    }
  }
  form.fieldRows = rows;
}

onMounted(async () => {
  if (!observableTypesStore.items.length) await observableTypesStore.fetchList();

  if (!isEdit.value) {
    loading.value = false;
    return;
  }

  const cached = store.findById(configId.value);
  const item = cached || (await getObserverConfig(configId.value)).item;
  if (item) {
    const observableType = observableTypesStore.items.find((t) => String(t.id) === String(item.observable_type_id));
    applyItem(item, observableType);
  } else {
    error.value = 'Observer config not found.';
  }
  loading.value = false;
});

// Rebuild locked field rows whenever the observable type selection changes
// while creating (the picker is disabled once saved, see the template
// below) - each observable type's own observer_config_schema drives which
// fields must/can be extracted, generalizing the old plugin's hardcoded
// price/discount/available list.
watch(
  () => form.observable_type_id,
  () => {
    if (isEdit.value || loading.value) return;
    form.fieldRows = schemaFieldRows(selectedObservableType.value);
    // Reset rather than let SchemaFieldsForm/SchemaDrivenForm silently keep
    // unrendered keys from the previous type's own schema around.
    form.mechanismConfig = {};
    testProperties.value = {};
  },
);

function rowToField(row) {
  const def = { temporal: row.temporal || undefined };
  if (row.mode === 'compute') {
    def.compute = row.compute.trim();
  } else {
    def.selector = (row.selector || []).map((v) => v.trim()).filter(Boolean);
  }
  if (row.transform.trim()) def.transform = row.transform.trim();
  if (row.validate.trim()) def.validate = row.validate.trim();
  return def;
}

function buildPayload() {
  const fields = {};
  for (const row of form.fieldRows) {
    fields[row.name.trim()] = rowToField(row);
  }
  return {
    name: form.name,
    observable_type_id: Number(form.observable_type_id),
    enabled: form.enabled,
    fields,
    mechanism_config: form.mechanismConfig,
  };
}

function validateFieldRows() {
  const names = new Set();
  for (const row of form.fieldRows) {
    const name = row.name.trim();
    if (!name) return 'Every field needs a name.';
    if (names.has(name)) return `Duplicate field name: ${name}`;
    names.add(name);
  }
  return null;
}

async function onSubmit() {
  error.value = '';
  if (!form.name.trim()) {
    error.value = 'Name is required.';
    return;
  }
  if (!form.observable_type_id) {
    error.value = 'Observable type is required.';
    return;
  }
  const fieldsError = validateFieldRows();
  if (fieldsError) {
    error.value = fieldsError;
    return;
  }

  saving.value = true;
  try {
    if (isEdit.value) {
      await store.update(configId.value, buildPayload());
    } else {
      await store.create(buildPayload());
    }
    router.push('/observer_configs');
  } catch (err) {
    if (err instanceof HTTPError) {
      const body = err.response.body;
      error.value = body?.message || body?.error || 'Save failed';
    } else {
      error.value = 'Save failed';
    }
  } finally {
    saving.value = false;
  }
}

async function runTest() {
  testError.value = '';
  testResult.value = null;
  hasTested.value = false;
  if (!selectedObservableType.value) {
    testError.value = 'Observable type is required.';
    return;
  }

  testing.value = true;
  try {
    const res = isEdit.value
      ? await testObserverConfig(configId.value, { properties: testProperties.value })
      : await testUnregisteredObserverConfig({ ...buildPayload(), properties: testProperties.value });
    testResult.value = res.data ?? null;
    hasTested.value = true;
  } catch (err) {
    if (err instanceof HTTPError) {
      const body = err.response.body;
      testError.value = body?.message || body?.error || 'Test failed';
    } else {
      testError.value = err.message || 'Test failed';
    }
  } finally {
    testing.value = false;
  }
}
</script>

<template>
  <div class="max-w-3xl">
    <h1 class="text-xl font-semibold text-slate-900 dark:text-slate-100">
      {{ isEdit ? `Edit observer config #${configId}` : 'New observer config' }}
    </h1>

    <p v-if="loading" class="mt-4 text-sm text-slate-500 dark:text-slate-400">Loading...</p>

    <form v-else class="mt-4 space-y-5 rounded-lg border border-slate-200 bg-white p-5 dark:border-slate-700 dark:bg-slate-800" @submit.prevent="onSubmit">
      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <div>
          <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="observer-config-name">Name</label>
          <input
            id="observer-config-name"
            v-model="form.name"
            type="text"
            maxlength="60"
            required
            class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          />
        </div>
        <label class="mt-6 flex items-center gap-2 text-sm text-slate-700 dark:text-slate-300">
          <input v-model="form.enabled" type="checkbox" />
          Enabled
        </label>
      </div>

      <div>
        <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="observer-config-observable-type">Observable type</label>
        <select
          id="observer-config-observable-type"
          v-model="form.observable_type_id"
          required
          :disabled="isEdit"
          class="mt-1 w-full max-w-sm rounded border border-slate-300 px-2 py-1.5 text-sm disabled:opacity-50 dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
        >
          <option value="" disabled>Select a type</option>
          <option v-for="t in observableTypesStore.items" :key="t.id" :value="String(t.id)">{{ t.label || t.name }}</option>
        </select>
        <p v-if="!isEdit" class="mt-1 text-xs text-slate-500 dark:text-slate-400">
          Can't be changed after saving - determines which fields below are required.
        </p>
      </div>

      <div class="border-t border-slate-200 pt-4 dark:border-slate-700">
        <ObserverFieldEditor v-model="form.fieldRows" label="Fields" />
        <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
          Fields marked "required" come from the selected observable type's own observer config
          schema and are always extracted. In selector mode, use CSS selectors to select the HTML
          element (find them via your browser's dev tools); in compute mode, derive the value
          from other fields with an arithmetic expression, e.g.
          <code class="font-mono">(original_price - price) / original_price * 100</code>. Add
          extra fields for helper values - mark one temporal to keep it out of the final result
          while still letting another field's compute expression reference it.
        </p>
      </div>

      <div class="border-t border-slate-200 pt-4 dark:border-slate-700">
        <h2 class="text-sm font-semibold text-slate-900 dark:text-slate-100">Observer options</h2>
        <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
          Fields defined on the selected observable type's own observer mechanism schema (see the
          Observable Types plugin) - controls HOW the observer reaches its source.
        </p>
        <SchemaFieldsForm
          :schema="selectedObservableType?.observer_mechanism_schema || []"
          v-model="form.mechanismConfig"
          class="mt-2"
        />
      </div>

      <p v-if="error" class="text-sm text-red-600 dark:text-red-400">{{ error }}</p>

      <div class="flex justify-end gap-2">
        <RouterLink
          to="/observer_configs"
          class="rounded px-3 py-1.5 text-sm font-medium text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-700"
        >
          Cancel
        </RouterLink>
        <button
          type="submit"
          :disabled="saving"
          class="rounded bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50 dark:bg-slate-700 dark:hover:bg-slate-600"
        >
          {{ saving ? 'Saving...' : 'Save' }}
        </button>
      </div>
    </form>

    <div v-if="!loading" class="mt-6 rounded-lg border border-slate-200 bg-white p-5 dark:border-slate-700 dark:bg-slate-800">
      <h2 class="text-sm font-semibold text-slate-900 dark:text-slate-100">Test</h2>
      <p class="mt-1 text-sm text-slate-500 dark:text-slate-400">
        Run the current field selectors against a real URL. Nothing is saved.
      </p>
      <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
        Requires at least one connected worker (standalone or embedded) to pick it up - see
        <RouterLink to="/workers" class="underline">workers</RouterLink>.
      </p>
      <SchemaDrivenForm
        v-if="selectedObservableType"
        v-model="testProperties"
        :schema="selectedObservableType.properties"
        class="mt-3"
      />
      <div class="mt-3 flex justify-end">
        <button
          type="button"
          :disabled="testing"
          class="flex items-center gap-1.5 rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-100 disabled:opacity-50 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
          @click="runTest"
        >
          <IconFlask class="h-4 w-4" />
          {{ testing ? 'Running on worker...' : 'Run test' }}
        </button>
      </div>

      <p v-if="testError" class="mt-3 text-sm text-red-600 dark:text-red-400">{{ testError }}</p>
      <pre v-if="hasTested && !testError" class="mt-3 overflow-x-auto rounded bg-slate-50 p-3 text-xs dark:bg-slate-900">{{ JSON.stringify(testResult, null, 2) }}</pre>
    </div>
  </div>
</template>
