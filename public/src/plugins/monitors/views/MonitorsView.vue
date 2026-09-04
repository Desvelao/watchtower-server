<script setup>
import { onMounted, ref, reactive, computed } from 'vue';
import { listMonitors } from '../../../services/api/monitors';
import { formatDate, formatUptime } from '../../../utils/date';
import DataTable from '../../../components/common/DataTable.vue';
import IconEye from '../../../components/common/icons/IconEye.vue';

const CONNECTION_TYPES = ['http', 'mqtt', 'embedded'];

const columns = [
  { key: 'monitor_id', label: 'Monitor', class: 'font-medium' },
  { key: 'connection_type', label: 'Connection' },
  { key: 'capabilities', label: 'Capabilities' },
  { key: 'item_filter', label: 'Item filter' },
  { key: 'version', label: 'Version' },
  { key: 'uptime_seconds', label: 'Uptime' },
  { key: 'last_seen_at', label: 'Last seen' },
];

const items = ref([]);
const loading = ref(true);
const error = ref('');

const filters = reactive({ search: '', connection_type: '', capability: '' });

async function refresh() {
  loading.value = true;
  try {
    const { items: fetched } = await listMonitors();
    items.value = fetched || [];
    error.value = '';
  } catch (err) {
    error.value = 'Failed to load monitors.';
  } finally {
    loading.value = false;
  }
}

onMounted(refresh);

const capabilityOptions = computed(() => {
  const set = new Set();
  for (const m of items.value) {
    for (const c of m.capabilities || []) set.add(c);
  }
  return [...set].sort();
});

const otherFields = computed(() => [
  {
    key: 'connection_type',
    label: 'Connection',
    type: 'select',
    options: [{ value: '', label: 'Any' }, ...CONNECTION_TYPES.map((type) => ({ value: type, label: type }))],
  },
  {
    key: 'capability',
    label: 'Capability',
    type: 'select',
    options: [{ value: '', label: 'Any' }, ...capabilityOptions.value.map((c) => ({ value: c, label: c }))],
  },
]);

const searchField = { key: 'search', label: 'Search', placeholder: 'ID or version' };

function onFilterUpdate(patch) {
  Object.assign(filters, patch);
}

const filteredItems = computed(() => {
  const search = filters.search.trim().toLowerCase();
  return items.value.filter((m) => {
    if (search) {
      const haystack = `${m.monitor_id || ''} ${m.version || ''} ${m.item_filter || ''}`.toLowerCase();
      if (!haystack.includes(search)) return false;
    }
    if (filters.connection_type && m.connection_type !== filters.connection_type) {
      return false;
    }
    if (filters.capability && !(m.capabilities || []).includes(filters.capability)) {
      return false;
    }
    return true;
  });
});

const emptyText = computed(() =>
  items.value.length === 0 ? 'No monitors yet.' : 'No monitors match the current filters.',
);
</script>

<template>
  <DataTable
    title="Monitors"
    :columns="columns"
    :items="filteredItems"
    id-key="monitor_id"
    :loading="loading"
    :error="error"
    :empty-text="emptyText"
    :other-fields="otherFields"
    :search="searchField"
    :filters="filters"
    @refresh="refresh"
    @update:filters="onFilterUpdate"
  >
    <template #description>
      <p class="mt-2 text-sm text-slate-500 dark:text-slate-400">
        Scraping-agent monitors registered with the system, showing connection type, capabilities,
        version, and last heartbeat.
      </p>
    </template>

    <template #cell-connection_type="{ value }">{{ value || '—' }}</template>
    <template #cell-capabilities="{ value, filterBy }">
      <button
        v-for="capability in value || []"
        :key="capability"
        type="button"
        title="Filter by this capability"
        class="mr-1 inline-block cursor-pointer rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-600 hover:bg-slate-200 dark:bg-slate-700 dark:text-slate-300 dark:hover:bg-slate-600"
        @click="filterBy('capability', capability)"
      >
        {{ capability }}
      </button>
      <span v-if="!(value || []).length" class="text-xs text-slate-400 dark:text-slate-500">—</span>
    </template>
    <template #cell-item_filter="{ value }">
      <span v-if="value" class="font-mono text-xs text-slate-700 dark:text-slate-300">{{ value }}</span>
      <span v-else class="text-xs text-slate-400 dark:text-slate-500">All items</span>
    </template>
    <template #cell-version="{ value }">{{ value || '—' }}</template>
    <template #cell-uptime_seconds="{ value }">{{ formatUptime(value) }}</template>
    <template #cell-last_seen_at="{ value }">{{ value ? formatDate(value) : 'Never' }}</template>

    <template #row-actions="{ item: m }">
      <RouterLink
        :to="`/monitors/${m.monitor_id}`"
        title="View details"
        :aria-label="`View details for ${m.monitor_id}`"
        class="inline-flex rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
      >
        <IconEye class="h-4 w-4" />
      </RouterLink>
    </template>
  </DataTable>
</template>
