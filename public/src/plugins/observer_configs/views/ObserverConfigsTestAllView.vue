<script setup>
import { computed, onMounted, ref } from 'vue';
import { useObservableTypesStore } from '../../../stores/observableTypes';
import { testAllObserverConfigs } from '../../../services/api/observerConfigs';
import { HTTPError } from '../../../services/api/http';
import SchemaDrivenForm from '../../../components/common/SchemaDrivenForm.vue';

const observableTypesStore = useObservableTypesStore();

const observableTypeId = ref('');
const properties = ref({});
const testing = ref(false);
const error = ref('');
const result = ref(null);
const hasTested = ref(false);

const selectedObservableType = computed(() =>
  observableTypesStore.items.find((t) => String(t.id) === String(observableTypeId.value)),
);

onMounted(() => {
  if (!observableTypesStore.items.length) observableTypesStore.fetchList();
});

function onObservableTypeChange() {
  properties.value = {};
}

async function onSubmit() {
  error.value = '';
  result.value = null;
  hasTested.value = false;
  if (!observableTypeId.value) {
    error.value = 'Observable type is required.';
    return;
  }

  testing.value = true;
  try {
    const res = await testAllObserverConfigs({
      observable_type_id: Number(observableTypeId.value),
      properties: properties.value,
    });
    result.value = res.data ?? null;
    hasTested.value = true;
  } catch (err) {
    if (err instanceof HTTPError) {
      const body = err.response.body;
      error.value = body?.message || body?.error || 'Test failed';
    } else {
      error.value = err.message || 'Test failed';
    }
  } finally {
    testing.value = false;
  }
}
</script>

<template>
  <div class="max-w-xl">
    <h1 class="text-xl font-semibold text-slate-900 dark:text-slate-100">Test all observer configs</h1>
    <p class="mt-2 text-sm text-slate-500 dark:text-slate-400">
      Runs every saved
      <RouterLink to="/observer_configs" class="underline">observer config's</RouterLink>
      selectors, for one observable type, against these properties and shows the extracted
      values. Nothing is saved.
    </p>
    <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
      Requires at least one connected worker (standalone or embedded) to pick it up - see
      <RouterLink to="/workers" class="underline">workers</RouterLink>.
    </p>

    <form class="mt-4 space-y-4 rounded-lg border border-slate-200 bg-white p-5 dark:border-slate-700 dark:bg-slate-800" @submit.prevent="onSubmit">
      <div>
        <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="test-all-observable-type">Observable type</label>
        <select
          id="test-all-observable-type"
          v-model="observableTypeId"
          required
          class="mt-1 w-full max-w-sm rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          @change="onObservableTypeChange"
        >
          <option value="" disabled>Select a type</option>
          <option v-for="t in observableTypesStore.items" :key="t.id" :value="String(t.id)">{{ t.label || t.name }}</option>
        </select>
      </div>

      <SchemaDrivenForm
        v-if="selectedObservableType"
        v-model="properties"
        :schema="selectedObservableType.properties"
      />

      <p v-if="error" class="text-sm text-red-600 dark:text-red-400">{{ error }}</p>

      <div class="flex justify-end">
        <button
          type="submit"
          :disabled="testing"
          class="rounded bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50 dark:bg-slate-700 dark:hover:bg-slate-600"
        >
          {{ testing ? 'Running on worker...' : 'Test' }}
        </button>
      </div>
    </form>

    <pre v-if="hasTested && !error" class="mt-6 overflow-x-auto rounded-lg border border-slate-200 bg-slate-50 p-4 text-xs dark:border-slate-700 dark:bg-slate-900">{{ JSON.stringify(result, null, 2) }}</pre>
  </div>
</template>
