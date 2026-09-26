<script setup>
import { computed, onMounted, reactive, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useObservableTypesStore } from '../../../stores/observableTypes';
import { HTTPError } from '../../../services/api/http';
import PropertySchemaEditor from '../components/PropertySchemaEditor.vue';

const props = defineProps({
  id: { type: String, default: null },
});

const route = useRoute();
const router = useRouter();
const store = useObservableTypesStore();

const observableTypeId = computed(() => props.id || route.params.id || null);
const isEdit = computed(() => !!observableTypeId.value);

const form = reactive({
  name: '',
  label: '',
  description: '',
  properties: [],
  observation_schema: [],
  observer_config_schema: [],
  observer_mechanism_schema: [],
});

const loading = ref(isEdit.value);
const saving = ref(false);
const error = ref('');

onMounted(async () => {
  if (!isEdit.value) return;

  if (!store.items.length) await store.fetchList();
  const existing = store.findById(observableTypeId.value);
  if (existing) {
    form.name = existing.name;
    form.label = existing.label || '';
    form.description = existing.description || '';
    form.properties = existing.properties || [];
    form.observation_schema = existing.observation_schema || [];
    form.observer_config_schema = existing.observer_config_schema || [];
    form.observer_mechanism_schema = existing.observer_mechanism_schema || [];
  } else {
    error.value = 'Observable type not found.';
  }
  loading.value = false;
});

async function onSubmit() {
  error.value = '';
  saving.value = true;
  try {
    const payload = {
      name: form.name,
      label: form.label,
      description: form.description,
      properties: form.properties,
      observation_schema: form.observation_schema,
      observer_config_schema: form.observer_config_schema,
      observer_mechanism_schema: form.observer_mechanism_schema,
    };
    if (isEdit.value) {
      await store.update(observableTypeId.value, payload);
    } else {
      await store.create(payload);
    }
    router.push('/observable-types');
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
  <div class="max-w-3xl">
    <h1 class="text-xl font-semibold text-slate-900 dark:text-slate-100">
      {{ isEdit ? `Edit observable type #${observableTypeId}` : 'New observable type' }}
    </h1>

    <p v-if="loading" class="mt-4 text-sm text-slate-500 dark:text-slate-400">Loading...</p>

    <form v-else class="mt-4 space-y-6 rounded-lg border border-slate-200 bg-white p-5 dark:border-slate-700 dark:bg-slate-800" @submit.prevent="onSubmit">
      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <div>
          <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="observable-type-name">Name</label>
          <input
            id="observable-type-name"
            v-model="form.name"
            type="text"
            required
            pattern="^[a-z][a-z0-9_]*$"
            title="Lowercase letters, digits and underscores, starting with a letter."
            :disabled="isEdit"
            class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm disabled:opacity-50 dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          />
        </div>
        <div>
          <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="observable-type-label">Label</label>
          <input
            id="observable-type-label"
            v-model="form.label"
            type="text"
            class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          />
        </div>
      </div>

      <div>
        <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="observable-type-description">Description</label>
        <textarea
          id="observable-type-description"
          v-model="form.description"
          rows="2"
          class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
        />
      </div>

      <div>
        <h2 class="text-sm font-semibold text-slate-900 dark:text-slate-100">Item properties</h2>
        <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
          Fields used to create an item of this type.
        </p>
        <PropertySchemaEditor v-model="form.properties" show-list-column-option class="mt-2" />
      </div>

      <div>
        <h2 class="text-sm font-semibold text-slate-900 dark:text-slate-100">Observation schema</h2>
        <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
          Fields recorded each time an item of this type is observed.
        </p>
        <PropertySchemaEditor v-model="form.observation_schema" show-list-column-option class="mt-2" />
      </div>

      <div>
        <h2 class="text-sm font-semibold text-slate-900 dark:text-slate-100">Observer config schema</h2>
        <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
          Fields an observer config for this type must/can supply extraction config for (see the Observer Configs plugin). Independent of the observation schema above - editing one does not change the other's requirements.
        </p>
        <PropertySchemaEditor v-model="form.observer_config_schema" show-list-column-option class="mt-2" />
      </div>

      <div>
        <h2 class="text-sm font-semibold text-slate-900 dark:text-slate-100">Observer mechanism schema</h2>
        <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
          Fields an observer config for this type can supply to configure HOW an observer reaches its source (e.g. URL matchers, page validation, headers, TLS verification) - field names must match what the underlying observer implementation expects. Group fields (e.g. "Page validation") to organize the observer config form; each field's description is shown near its input there.
        </p>
        <PropertySchemaEditor v-model="form.observer_mechanism_schema" show-list-column-option class="mt-2" />
      </div>

      <p v-if="error" class="text-sm text-red-600 dark:text-red-400">{{ error }}</p>

      <div class="flex justify-end gap-2">
        <RouterLink
          to="/observable-types"
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
