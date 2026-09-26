<script setup>
import { ref, watch } from 'vue';
import { useObservablesStore } from '../../../stores/observables';
import { getObservable } from '../../../services/api/observables';
import { formatDate } from '../../../utils/date';
import Flyout from '../../../components/common/Flyout.vue';
import CodeEditor from '../../../components/common/CodeEditor.vue';

const props = defineProps({
  observableId: { type: [String, Number], default: null },
});

const emit = defineEmits(['close']);

const store = useObservablesStore();

const observable = ref(null);
const loading = ref(false);
const error = ref('');
watch(
  () => props.observableId,
  async (id) => {
    observable.value = null;
    error.value = '';
    if (!id) return;

    loading.value = true;
    try {
      const cached = store.findById(id);
      if (cached) {
        observable.value = cached;
      } else {
        const { observable: fetched } = await getObservable(id);
        observable.value = fetched || null;
        if (!observable.value) error.value = 'Observable not found.';
      }
    } catch (err) {
      error.value = 'Failed to load observable details.';
    } finally {
      loading.value = false;
    }
  },
  { immediate: true },
);
</script>

<template>
  <Flyout :open="!!observableId" :title="`Observable #${observableId}`" @close="emit('close')">
    <p v-if="loading" class="mt-4 text-sm text-slate-500 dark:text-slate-400">Loading...</p>
    <p v-else-if="error" class="mt-4 text-sm text-red-600 dark:text-red-400">{{ error }}</p>

    <template v-else-if="observable">
      <section class="mt-4">
        <h3 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Details</h3>
        <table class="mt-2 w-full text-sm">
          <tbody class="divide-y divide-slate-100 dark:divide-slate-700">
            <tr>
              <td class="w-40 py-1.5 pr-3 text-slate-500 dark:text-slate-400">ID</td>
              <td class="py-1.5">{{ observable.id }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Name</td>
              <td class="py-1.5">{{ observable.name }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Enabled</td>
              <td class="py-1.5">{{ observable.enabled ? 'Enabled' : 'Disabled' }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Observable type</td>
              <td class="py-1.5">{{ observable.observable_type_id }}</td>
            </tr>
            <tr v-if="observable.url">
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">URL</td>
              <td class="py-1.5">
                <a :href="observable.url" target="_blank" rel="noopener noreferrer" class="underline hover:text-slate-900 dark:hover:text-slate-100">
                  {{ observable.url }}
                </a>
              </td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Created</td>
              <td class="py-1.5">{{ formatDate(observable.created_at) }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Updated</td>
              <td class="py-1.5">{{ formatDate(observable.updated_at) }}</td>
            </tr>
          </tbody>
        </table>
      </section>

      <section class="mt-4">
        <h3 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Properties</h3>
        <div class="mt-2">
          <CodeEditor :model-value="JSON.stringify(observable.properties || {}, null, 2)" language="json" read-only min-height="10rem" />
        </div>
      </section>
    </template>
  </Flyout>
</template>
