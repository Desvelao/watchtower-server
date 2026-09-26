<script setup>
import { onMounted, ref, watch } from 'vue';
import { useObservationsStore } from '../../../stores/observations';
import { useObservableTypesStore } from '../../../stores/observableTypes';
import { getObservation } from '../../../services/api/observations';
import { formatDate } from '../../../utils/date';
import { observableTypeLabel } from '../../../utils/observableType';
import Flyout from '../../../components/common/Flyout.vue';
import CodeEditor from '../../../components/common/CodeEditor.vue';

const props = defineProps({
  observationId: { type: [String, Number], default: null },
});

const emit = defineEmits(['close']);

const store = useObservationsStore();
const observableTypesStore = useObservableTypesStore();

onMounted(() => {
  if (!observableTypesStore.items.length) observableTypesStore.fetchList();
});

const observation = ref(null);
const loading = ref(false);
const error = ref('');
watch(
  () => props.observationId,
  async (id) => {
    observation.value = null;
    error.value = '';
    if (!id) return;

    loading.value = true;
    try {
      const cached = store.findById(id);
      if (cached) {
        observation.value = cached;
      } else {
        const { item } = await getObservation(id);
        observation.value = item || null;
        if (!observation.value) error.value = 'Observation not found.';
      }
    } catch (err) {
      error.value = 'Failed to load observation details.';
    } finally {
      loading.value = false;
    }
  },
  { immediate: true },
);
</script>

<template>
  <Flyout :open="!!observationId" :title="`Observation #${observationId}`" @close="emit('close')">
    <p v-if="loading" class="mt-4 text-sm text-slate-500 dark:text-slate-400">Loading...</p>
    <p v-else-if="error" class="mt-4 text-sm text-red-600 dark:text-red-400">{{ error }}</p>

    <template v-else-if="observation">
      <section class="mt-4">
        <h3 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Details</h3>
        <table class="mt-2 w-full text-sm">
          <tbody class="divide-y divide-slate-100 dark:divide-slate-700">
            <tr>
              <td class="w-40 py-1.5 pr-3 text-slate-500 dark:text-slate-400">ID</td>
              <td class="py-1.5">{{ observation.id }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Timestamp</td>
              <td class="py-1.5">{{ formatDate(observation.timestamp) }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Observable</td>
              <td class="py-1.5">{{ observation.observable?.name || observation.observable_id || '-' }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Type</td>
              <td class="py-1.5">{{ observableTypeLabel(observation.observable?.observable_type_id, observableTypesStore.items) }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Worker</td>
              <td class="py-1.5">{{ observation.worker || '-' }}</td>
            </tr>
          </tbody>
        </table>
      </section>

      <section class="mt-4">
        <h3 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Properties</h3>
        <div class="mt-2">
          <CodeEditor :model-value="JSON.stringify(observation.properties || {}, null, 2)" language="json" read-only min-height="10rem" />
        </div>
      </section>
    </template>
  </Flyout>
</template>
