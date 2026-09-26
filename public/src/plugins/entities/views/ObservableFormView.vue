<script setup>
import { computed, onMounted, reactive, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useObservablesStore } from '../../../stores/observables';
import { useObservableTypesStore } from '../../../stores/observableTypes';
import { listObservables } from '../../../services/api/observables';
import { HTTPError } from '../../../services/api/http';
import SchemaDrivenForm from '../../../components/common/SchemaDrivenForm.vue';

const props = defineProps({
  id: { type: String, default: null },
});

const route = useRoute();
const router = useRouter();
const store = useObservablesStore();
const observableTypesStore = useObservableTypesStore();

const observableId = computed(() => props.id || route.params.id || null);
const isEdit = computed(() => !!observableId.value);

const form = reactive({
  name: '',
  observable_type_id: '',
  enabled: true,
  properties: {},
});

const loading = ref(true);
const saving = ref(false);
const error = ref('');

const selectedObservableType = computed(() =>
  observableTypesStore.items.find((t) => String(t.id) === String(form.observable_type_id)),
);

// Only reset properties on a manual type change while creating - loading
// an existing observable's saved observable_type_id below must not wipe its
// already-loaded properties.
function onObservableTypeChange(event) {
  form.observable_type_id = event.target.value;
  form.properties = {};
}

onMounted(async () => {
  if (!observableTypesStore.items.length) await observableTypesStore.fetchList();

  if (!isEdit.value) {
    loading.value = false;
    return;
  }

  const cached = store.findById(observableId.value);
  const existing =
    cached ||
    (await listObservables({ id: observableId.value }).then((res) => res.items?.[0]).catch(() => null));

  if (existing) {
    form.name = existing.name;
    form.observable_type_id = existing.observable_type_id;
    form.enabled = existing.enabled;
    form.properties = { ...(existing.properties || {}) };
  } else {
    error.value = 'Observable not found.';
  }
  loading.value = false;
});

async function onSubmit() {
  error.value = '';

  if (!form.observable_type_id) {
    error.value = 'Observable type is required.';
    return;
  }

  const payload = isEdit.value
    ? { name: form.name, enabled: form.enabled, properties: form.properties }
    : { name: form.name, observable_type_id: form.observable_type_id, enabled: form.enabled, properties: form.properties };

  saving.value = true;
  try {
    if (isEdit.value) {
      await store.update(observableId.value, payload);
    } else {
      await store.create(payload);
    }
    router.push('/observables');
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
</script>

<template>
  <div class="max-w-2xl">
    <h1 class="text-xl font-semibold text-slate-900 dark:text-slate-100">
      {{ isEdit ? `Edit observable #${observableId}` : 'New observable' }}
    </h1>

    <p v-if="loading" class="mt-4 text-sm text-slate-500 dark:text-slate-400">Loading...</p>

    <form v-else class="mt-4 space-y-4 rounded-lg border border-slate-200 bg-white p-5 dark:border-slate-700 dark:bg-slate-800" @submit.prevent="onSubmit">
      <div>
        <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="observable-observable-type">Observable type</label>
        <select
          id="observable-observable-type"
          :value="form.observable_type_id"
          required
          :disabled="isEdit"
          class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm disabled:opacity-50 dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          @change="onObservableTypeChange"
        >
          <option value="" disabled>Select an observable type…</option>
          <option v-for="t in observableTypesStore.items" :key="t.id" :value="t.id">{{ t.label || t.name }}</option>
        </select>
      </div>

      <div>
        <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="observable-name">Name (optional)</label>
        <input
          id="observable-name"
          v-model="form.name"
          type="text"
          class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
        />
      </div>

      <div class="flex items-center gap-2">
        <input id="observable-enabled" v-model="form.enabled" type="checkbox" />
        <label class="text-sm font-medium text-slate-700 dark:text-slate-300" for="observable-enabled">Enabled</label>
      </div>

      <SchemaDrivenForm
        v-if="selectedObservableType"
        v-model="form.properties"
        :schema="selectedObservableType.properties"
      />

      <p v-if="error" class="text-sm text-red-600 dark:text-red-400">{{ error }}</p>

      <div class="flex justify-end gap-2">
        <RouterLink
          to="/observables"
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
  </div>
</template>
