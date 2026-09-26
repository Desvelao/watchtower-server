<script setup>
import { ref, watch } from 'vue';
import { useObservableTypesStore } from '../../../stores/observableTypes';
import { getObservableType } from '../../../services/api/observableTypes';
import { formatDate } from '../../../utils/date';
import Flyout from '../../../components/common/Flyout.vue';
import CodeEditor from '../../../components/common/CodeEditor.vue';

const props = defineProps({
  observableTypeId: { type: [String, Number], default: null },
});

const emit = defineEmits(['close']);

const store = useObservableTypesStore();

const observableType = ref(null);
const loading = ref(false);
const error = ref('');
watch(
  () => props.observableTypeId,
  async (id) => {
    observableType.value = null;
    error.value = '';
    if (!id) return;

    loading.value = true;
    try {
      const cached = store.findById(id);
      if (cached) {
        observableType.value = cached;
      } else {
        const { item } = await getObservableType(id);
        observableType.value = item || null;
        if (!observableType.value) error.value = 'Observable type not found.';
      }
    } catch (err) {
      error.value = 'Failed to load observable type details.';
    } finally {
      loading.value = false;
    }
  },
  { immediate: true },
);
</script>

<template>
  <Flyout :open="!!observableTypeId" :title="`Observable type #${observableTypeId}`" @close="emit('close')">
    <p v-if="loading" class="mt-4 text-sm text-slate-500 dark:text-slate-400">Loading...</p>
    <p v-else-if="error" class="mt-4 text-sm text-red-600 dark:text-red-400">{{ error }}</p>

    <template v-else-if="observableType">
      <section class="mt-4">
        <h3 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Details</h3>
        <table class="mt-2 w-full text-sm">
          <tbody class="divide-y divide-slate-100 dark:divide-slate-700">
            <tr>
              <td class="w-40 py-1.5 pr-3 text-slate-500 dark:text-slate-400">ID</td>
              <td class="py-1.5">{{ observableType.id }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Name</td>
              <td class="py-1.5">{{ observableType.name }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Label</td>
              <td class="py-1.5">{{ observableType.label || '-' }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Description</td>
              <td class="py-1.5">{{ observableType.description || '-' }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Created</td>
              <td class="py-1.5">{{ formatDate(observableType.created_at) }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Updated</td>
              <td class="py-1.5">{{ formatDate(observableType.updated_at) }}</td>
            </tr>
          </tbody>
        </table>
      </section>

      <section class="mt-4">
        <h3 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Properties schema</h3>
        <div class="mt-2">
          <CodeEditor :model-value="JSON.stringify(observableType.properties || [], null, 2)" language="json" read-only min-height="10rem" />
        </div>
      </section>

      <section class="mt-4">
        <h3 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Observation schema</h3>
        <div class="mt-2">
          <CodeEditor :model-value="JSON.stringify(observableType.observation_schema || [], null, 2)" language="json" read-only min-height="10rem" />
        </div>
      </section>
    </template>
  </Flyout>
</template>
