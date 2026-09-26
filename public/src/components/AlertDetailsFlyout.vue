<script setup>
import { onMounted, ref, watch } from 'vue';
import { useAlertsStore } from '../stores/alerts';
import { useObservableTypesStore } from '../stores/observableTypes';
import { getAlert } from '../services/api/alerts';
import { formatDate } from '../utils/date';
import { observableTypeLabel } from '../utils/observableType';
import AlertSeverityBadge from './AlertSeverityBadge.vue';
import Flyout from './common/Flyout.vue';

const props = defineProps({
  alertId: { type: [String, Number], default: null },
});

const emit = defineEmits(['close']);

const store = useAlertsStore();
const observableTypesStore = useObservableTypesStore();

onMounted(() => {
  if (!observableTypesStore.items.length) observableTypesStore.fetchList();
});

const alert = ref(null);
const loading = ref(false);
const error = ref('');
watch(
  () => props.alertId,
  async (id) => {
    alert.value = null;
    error.value = '';
    if (!id) return;

    loading.value = true;
    try {
      // Fast path: reuse the row already loaded in the list. Falls back to
      // a server lookup by id.
      const cached = store.findById(id);
      if (cached) {
        alert.value = cached;
      } else {
        const { item } = await getAlert(id);
        alert.value = item || null;
        if (!alert.value) error.value = 'Alert not found.';
      }
    } catch (err) {
      error.value = 'Failed to load alert details.';
    } finally {
      loading.value = false;
    }
  },
  { immediate: true },
);
</script>

<template>
  <Flyout :open="!!alertId" :title="`Alert #${alertId}`" @close="emit('close')">
    <p v-if="loading" class="mt-4 text-sm text-slate-500 dark:text-slate-400">Loading...</p>
    <p v-else-if="error" class="mt-4 text-sm text-red-600 dark:text-red-400">{{ error }}</p>

    <template v-else-if="alert">
        <section class="mt-4">
          <h3 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Details</h3>
          <table class="mt-2 w-full text-sm">
            <tbody class="divide-y divide-slate-100 dark:divide-slate-700">
              <tr>
                <td class="w-40 py-1.5 pr-3 text-slate-500 dark:text-slate-400">ID</td>
                <td class="py-1.5">{{ alert.id }}</td>
              </tr>
              <tr>
                <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Severity</td>
                <td class="py-1.5"><AlertSeverityBadge :severity="alert.severity" /></td>
              </tr>
              <tr>
                <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Type</td>
                <td class="py-1.5">{{ observableTypeLabel(alert.observable_type_id, observableTypesStore.items) }}</td>
              </tr>
              <tr>
                <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Payload</td>
                <td class="py-1.5">{{ alert.payload || '-' }}</td>
              </tr>
              <tr>
                <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Matched rule</td>
                <td class="py-1.5">
                  <RouterLink
                    v-if="alert.rule_id"
                    :to="`/rules/${alert.rule_id}/edit`"
                    class="underline hover:text-slate-900 dark:hover:text-slate-100"
                  >
                    {{ alert.rule_name }}
                  </RouterLink>
                  <span v-else>-</span>
                </td>
              </tr>
              <tr>
                <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Source</td>
                <td class="py-1.5">{{ alert.source || '-' }}</td>
              </tr>
              <tr>
                <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Observable</td>
                <td class="py-1.5">{{ alert.observable_id || '-' }}</td>
              </tr>
              <tr>
                <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Tags</td>
                <td class="py-1.5">
                  <span
                    v-for="tag in alert.tags || []"
                    :key="tag"
                    class="mr-1 inline-block rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-600 dark:bg-slate-700 dark:text-slate-300"
                  >
                    {{ tag }}
                  </span>
                  <span v-if="!alert.tags || alert.tags.length === 0" class="text-slate-400 dark:text-slate-500">-</span>
                </td>
              </tr>
              <tr>
                <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Created</td>
                <td class="py-1.5">{{ formatDate(alert.created_at) }}</td>
              </tr>
              <tr>
                <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Updated</td>
                <td class="py-1.5">{{ formatDate(alert.updated_at) }}</td>
              </tr>
            </tbody>
          </table>
        </section>
    </template>
  </Flyout>
</template>
