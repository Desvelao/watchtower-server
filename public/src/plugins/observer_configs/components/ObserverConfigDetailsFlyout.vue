<script setup>
import { ref, watch } from 'vue';
import { useObserverConfigsStore } from '../../../stores/observerConfigs';
import { getObserverConfig } from '../../../services/api/observerConfigs';
import { formatDate } from '../../../utils/date';
import Flyout from '../../../components/common/Flyout.vue';

// Generic, schema-agnostic rendering of one mechanism_config value - this
// flyout doesn't have the observable type's observer_mechanism_schema handy
// (and doesn't need it for a read-only display), so it just formats
// whatever shape was saved: arrays comma-joined, objects (map fields) as
// `key: value` pairs, everything else as plain text.
function formatMechanismValue(value) {
  if (Array.isArray(value)) return value.join(', ') || '-';
  if (value && typeof value === 'object') {
    const entries = Object.entries(value).map(([k, v]) => `${k}: ${v}`);
    return entries.join(', ') || '-';
  }
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  return value === undefined || value === null || value === '' ? '-' : String(value);
}

const props = defineProps({
  configId: { type: [String, Number], default: null },
});

const emit = defineEmits(['close']);

const store = useObserverConfigsStore();

const item = ref(null);
const loading = ref(false);
const error = ref('');
watch(
  () => props.configId,
  async (id) => {
    item.value = null;
    error.value = '';
    if (!id) return;

    loading.value = true;
    try {
      const cached = store.findById(id);
      if (cached) {
        item.value = cached;
      } else {
        const { item: fetched } = await getObserverConfig(id);
        item.value = fetched || null;
        if (!item.value) error.value = 'Observer config not found.';
      }
    } catch (err) {
      error.value = 'Failed to load observer config details.';
    } finally {
      loading.value = false;
    }
  },
  { immediate: true },
);
</script>

<template>
  <Flyout :open="!!configId" :title="`Observer config #${configId}`" @close="emit('close')">
    <p v-if="loading" class="mt-4 text-sm text-slate-500 dark:text-slate-400">Loading...</p>
    <p v-else-if="error" class="mt-4 text-sm text-red-600 dark:text-red-400">{{ error }}</p>

    <template v-else-if="item">
      <section class="mt-4">
        <h3 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Details</h3>
        <table class="mt-2 w-full text-sm">
          <tbody class="divide-y divide-slate-100 dark:divide-slate-700">
            <tr>
              <td class="w-40 py-1.5 pr-3 text-slate-500 dark:text-slate-400">ID</td>
              <td class="py-1.5">{{ item.id }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Name</td>
              <td class="py-1.5">{{ item.name }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Enabled</td>
              <td class="py-1.5">{{ item.enabled ? 'Yes' : 'No' }}</td>
            </tr>
          </tbody>
        </table>
      </section>

      <section class="mt-4 space-y-2 text-sm text-slate-600 dark:text-slate-300">
        <h3 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Fields</h3>
        <div v-for="(def, name) in item.fields || {}" :key="name">
          <span class="font-medium text-slate-900 dark:text-slate-100">{{ name }}</span>
          <span v-if="def.temporal" class="ml-1 rounded bg-amber-100 px-1 text-xs text-amber-800 dark:bg-amber-900/40 dark:text-amber-300">temporal</span>
          -
          <template v-if="def.compute">
            compute: <span class="font-mono text-xs">{{ def.compute }}</span>,
          </template>
          <template v-else>
            selector: <span class="font-mono text-xs">{{ (def.selector || []).join(', ') }}</span>,
          </template>
          transform: <span class="font-mono text-xs">{{ def.transform || '-' }}</span>,
          validate: <span class="font-mono text-xs">{{ def.validate || '-' }}</span>
        </div>
      </section>

      <section class="mt-4 space-y-2 text-sm text-slate-600 dark:text-slate-300">
        <h3 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Observer options</h3>
        <div v-if="!Object.keys(item.mechanism_config || {}).length">-</div>
        <div v-for="(value, name) in item.mechanism_config || {}" :key="name">
          <span class="font-medium text-slate-900 dark:text-slate-100">{{ name }}</span>: <span class="font-mono text-xs">{{ formatMechanismValue(value) }}</span>
        </div>
      </section>

      <section class="mt-4 space-y-2 text-sm text-slate-600 dark:text-slate-300">
        <div>Created: {{ formatDate(item.created_at) }}</div>
        <div>Updated: {{ formatDate(item.updated_at) }}</div>
      </section>
    </template>
  </Flyout>
</template>
